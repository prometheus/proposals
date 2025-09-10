#!/bin/bash

# This script detects proposals that does not follow proposal file format.
# It supports old proposal filenames format left for compatibility, but those needs to
# have a corresponding new format file.

set -o errexit
set -o pipefail
set -o nounset


SCRIPT_DIR="$(
	cd -- "$(dirname "$0")" >/dev/null 2>&1
	pwd -P
)"

OLD_FORMAT="^[0-9]{4}-[0-9]{2}-[0-9]{2}[_-](.*)\.md$"
NEW_FORMAT="^[0-9]{4}-(.*)\.md$"

pushd "${SCRIPT_DIR}/.."

# Safety check to remind ourselves to update this script when we change template.
TEMPLATE_FILE="./0000-template.md"
if [[ ! -f ${TEMPLATE_FILE} ]]; then
  echo "🔥  Did ${TEMPLATE_FILE} template change? Make sure to update this script if the file format changed!"
  exit 1
fi
# Safety check for regex.
if [[ ! "$(basename "$TEMPLATE_FILE")" =~ ${NEW_FORMAT}  ]]; then
  echo "🔥  Did ${TEMPLATE_FILE} template change? Template filename does not match script hardcoded format regex. Make sure to update this script if the file format changed!"
  exit 1
fi

mapfile -t files < <(ls ./proposals/*.md)

# Use an associative array to store proposals with the correct format.
# This acts like a "set" for efficient lookups.
declare -A correct_proposals

found_issue=false

# Get correct proposals first and detect
for filename in "${files[@]}"; do
    # Filter out old names as the old format matches new.
    if [[ "$(basename "$filename")" =~ ${OLD_FORMAT} ]]; then
      continue
    fi

    # Regex to match files like "0028-utf8.md"
    if [[ "$(basename "$filename")" =~ ${NEW_FORMAT} ]]; then
        # BASH_REMATCH[1] contains the captured group (the slug)
        slug="${BASH_REMATCH[1]}"

        # Add the slug to our set. The value '1' is arbitrary.
        correct_proposals["$slug"]=1
    else
      echo "🔥  Wrong proposal filename format detected: '$filename'"
      found_issue=true
    fi
done

# Step 2: Iterate through old format and check if it has a matching new format.
for filename in "${files[@]}"; do
    if [[ "$(basename "$filename")" =~ ${OLD_FORMAT} ]]; then
        slug="${BASH_REMATCH[1]}"

        # Check if the slug from the date-prefixed file does NOT exist in our set.
        # The '-v' operator specifically checks for the existence of a key.
        if [[ ! -v correct_proposals["$slug"] ]]; then
            echo "🔥  Old proposal filename format does not have a corresponding new format file replacement (if it's new proposal, please ONLY create a file with a new format): '$filename'"
            found_issue=true
        fi
    fi
done

# Step 3: Provide a summary of the findings.
if ! $found_issue; then
    echo "✅ All proposal file names have a correct format."
else
    echo "🔥  Found one more or more proposal files with invalid format. Make sure your new proposal(s) follow ${TEMPLATE_FILE}, so ./proposals/XXX-<proposal>.md file format!"
    exit 1
fi
