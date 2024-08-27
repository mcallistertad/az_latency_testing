#!/bin/bash

# Function to display usage
usage() {
    echo "Usage: $0 <json_file> [--ipv6] [--output-dir <directory>] [--format <csv|txt>] [-g | -aw | -az]"
    echo "  --ipv6            Optionally include IPv6 addresses in the latency test."
    echo "  --output-dir      Specify a directory for output files."
    echo "  --format          Specify output format: 'csv' or 'txt'. Default is 'txt'."
    echo "  -g                Specify Google Cloud format."
    echo "  -aw               Specify AWS format."
    echo "  -az               Specify Azure format."
    exit 1
}

# Check if a filename was provided as an argument
if [ -z "$1" ]; then
    usage
fi

# Default values
test_ipv6=false
output_dir="Results"
output_format="txt"
provider=""

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --ipv6) test_ipv6=true ;;
        --output-dir) shift; output_dir="$1" ;;
        --format) shift; output_format="$1" ;;
        -g) provider="google" ;;
        -aw) provider="aws" ;;
        -az) provider="azure" ;;
        *) json_file="$1" ;;
    esac
    shift
done

# Check if provider is set
if [ -z "$provider" ]; then
    echo "Error: No provider specified."
    usage
fi

# Validate the JSON file
if ! jq empty "$json_file" 2>/dev/null; then
    echo "The JSON file is malformed or invalid."
    exit 1
fi

# Check for required tools
for cmd in jq gshuf parallel; do
    if ! command -v $cmd &> /dev/null; then
        echo "$cmd is required but not installed. Please install it."
        exit 1
    fi
done

# Create the output directory if it doesn't exist
mkdir -p "$output_dir"

# Function to display a progress bar
show_progress() {
    local progress=$1
    local total=$2
    local percent=$((progress * 100 / total))
    local progress_bar=$(printf "%-${percent}s" "#" | tr ' ' '#')
    printf "\r[%-100s] %d%% (%d of %d regions)" "$progress_bar" "$percent" "$progress" "$total"
}

# Function to extract and ping IP addresses by region
test_latency_by_region() {
    local region=$1
    shift
    local ip_prefixes=("$@")

    echo "Testing region: $region with ${#ip_prefixes[@]} IP prefixes"

    if [ ${#ip_prefixes[@]} -eq 0 ]; then
        echo "No IP prefixes found for region: $region"
        return
    fi

    # Extract base IP addresses from CIDR blocks
    local ip_addresses=()
    for prefix in "${ip_prefixes[@]}"; do
        if [ "$test_ipv6" = false ] && [[ "$prefix" == *:* ]]; then
            continue  # Skip IPv6 addresses if not testing IPv6
        fi
        # Check if prefix is not null and valid
        if [ -n "$prefix" ]; then
            base_ip=$(echo "$prefix" | awk -F '/' '{print $1}')
            ip_addresses+=("$base_ip")
        fi
    done

    echo -e "\nTesting region: $region with ${#ip_addresses[@]} IPs"

    # Calculate number of IPs to test (20% of total IPs, or at least 3)
    local num_ips_total=${#ip_addresses[@]}
    local num_ips_to_test=3
    if [ $num_ips_total -gt 0 ]; then
        num_ips_to_test=$(echo "scale=0; ($num_ips_total * 0.2)/1" | bc)
        num_ips_to_test=$(($num_ips_to_test < 3 ? 3 : $num_ips_to_test))
    fi

    echo "Number of IPs to test: $num_ips_to_test"

    # Sample IPs randomly using gshuf
    sampled_ips=($(gshuf -e "${ip_addresses[@]}" -n "$num_ips_to_test"))

    echo -e "\nTesting region: $region with $num_ips_to_test IPs (Sampled ${#sampled_ips[@]} IPs)"
    echo "Sampled IPs: ${sampled_ips[@]}"

    # Create a temporary file to store the results
    temp_file=$(mktemp)

    # Run latency tests in parallel using the external script
    parallel --jobs 16 ./test_latency.sh ::: "${sampled_ips[@]}" > "$temp_file"

    # Process the results
    latencies=()
    while IFS=' ' read -r ip latency; do
        if [[ "$latency" != "N/A" && "$latency" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            echo "IP: $ip, Latency: $latency ms"
            latencies+=("$latency")
        else
            echo "IP: $ip, Latency: N/A"
        fi
    done < "$temp_file"

    # Clean up
    rm "$temp_file"

    # Calculate statistics only if there are valid latencies
    if [ ${#latencies[@]} -gt 0 ]; then
        min_latency=$(printf '%s\n' "${latencies[@]}" | sort -n | head -n 1)
        max_latency=$(printf '%s\n' "${latencies[@]}" | sort -n | tail -n 1)
        avg_latency=$(printf '%s\n' "${latencies[@]}" | awk '{sum+=$1} END {print sum/NR}')
    else
        min_latency="N/A"
        max_latency="N/A"
        avg_latency="N/A"
    fi

    # Output results to the single file with date and time prefix
    local output_file="$output_dir/${provider}_latency_results.$output_format"

    if [ "$output_format" == "txt" ]; then
        {
            echo -e "\n[$(date '+%Y-%m-%d %H:%M:%S')] Results for region: $region"
            echo "Min Latency: ${min_latency:-N/A} ms"
            echo "Max Latency: ${max_latency:-N/A} ms"
            echo "Avg Latency: ${avg_latency:-N/A} ms"
            echo ""
        } >> "$output_file"
    elif [ "$output_format" == "csv" ]; then
        {
            echo "$region,$min_latency,$max_latency,$avg_latency" >> "$output_file"
        }
    else
        echo "Unsupported output format: $output_format. Only 'txt' or 'csv' are allowed."
        exit 1
    fi
}

# Main script execution
regions=$(jq -r '(.prefixes[]?.region // empty) | select(length > 0)' "$json_file")

if [ "$provider" == "google" ]; then
    regions=$(jq -r '.prefixes[].scope // empty' "$json_file" | sort -u)
elif [ "$provider" == "aws" ]; then
    regions=$(jq -r '.prefixes[].region // empty' "$json_file" | sort -u)
elif [ "$provider" == "azure" ]; then
    regions=$(jq -r '.values[].properties.region // empty' "$json_file" | sort -u)
else
    echo "Unsupported provider: $provider"
    exit 1
fi

total_regions=$(echo "$regions" | wc -l)
current_region=0

for region in $regions; do
    ((current_region++))
    case "$provider" in
        aws)
            ip_prefixes=($(jq -r --arg region "$region" '.prefixes[] | select(.region==$region) | .ip_prefix // empty' "$json_file" | grep -v '^null$'))
            ipv6_prefixes=($(jq -r --arg region "$region" '.ipv6_prefixes[] | select(.region==$region) | .ipv6_prefix // empty' "$json_file" | grep -v '^null$'))
            ip_prefixes+=("${ipv6_prefixes[@]}")
            ;;
        google)
            ip_prefixes=($(jq -r --arg region "$region" '.prefixes[] | select(.scope==$region) | .ipv4Prefix, .ipv6Prefix // empty' "$json_file" | grep -v '^null$'))
            ;;
        azure)
            if [ "$test_ipv6" = false ]; then
                ip_prefixes=($(jq -r --arg region "$region" '.values[] | select(.properties.region==$region) | .properties.addressPrefixes[] // empty' "$json_file" | grep -v '^null$'))
            else
                ip_prefixes=($(jq -r --arg region "$region" '.values[] | select(.properties.region==$region) | .properties.addressPrefixes[], .properties.ipv6AddressPrefixes[] // empty' "$json_file" | grep -v '^null$'))
            fi
            ;;
    esac

    # Debugging: print extracted IP prefixes
    echo "Extracted IP prefixes for region $region: ${ip_prefixes[@]}"

    if [ ${#ip_prefixes[@]} -eq 0 ]; then
        echo "No IP prefixes found for region: $region"
        continue
    fi

    test_latency_by_region "$region" "${ip_prefixes[@]}"
    show_progress "$current_region" "$total_regions"
done

echo -e "\nLatency tests completed. Results are saved in $output_dir/${provider}_latency_results.$output_format."
