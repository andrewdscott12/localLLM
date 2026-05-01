#!/bin/bash

# Function to display date using figlet if available, otherwise use fallback
display_date() {
    # Get today's date in MM/DD/YYYY format
    date_str=$(date +"%m/%d/%Y")
    
    echo "Today's date: $date_str"
    echo
    
    # Check if figlet is available
    if command -v figlet &> /dev/null; then
        echo "Using figlet:"
        echo
        figlet "$date_str"
    else
        echo "Figlet not available. Using fallback method:"
        echo
        # Fallback: simple text formatting
        echo "Date: $date_str"
        echo "Format: MM/DD/YYYY"
    fi
}

# Main execution
display_date