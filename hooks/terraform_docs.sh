#!/usr/bin/env bash
set -eo pipefail

# globals variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

insertion_marker_begin="<!-- BEGIN_TF_DOCS -->"
insertion_marker_end="<!-- END_TF_DOCS -->"

# Old markers used by the hook before the introduction of the terraform-docs markers
readonly old_insertion_marker_begin="<!-- BEGINNING OF PRE-COMMIT-TERRAFORM DOCS HOOK -->"
readonly old_insertion_marker_end="<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->"

function main {
  common::initialize "$SCRIPT_DIR"
  common::parse_cmdline "$@"
  common::export_provided_env_vars "${ENV_VARS[@]}"
  common::parse_and_export_env_vars
  # Support for setting relative PATH to .terraform-docs.yml config.
  for i in "${!ARGS[@]}"; do
    ARGS[i]=${ARGS[i]/--config=/--config=$(pwd)\/}
  done
  # shellcheck disable=SC2153 # False positive
  terraform_docs_ "${HOOK_CONFIG[*]}" "${ARGS[*]}" "${FILES[@]}"
}

#######################################################################
# Function to replace old markers with new markers affected files
# Globals:
#   insertion_marker_begin - Standard insertion marker at beginning
#   insertion_marker_end - Standard insertion marker at the end
#   old_insertion_marker_begin - Old insertion marker at beginning
#   old_insertion_marker_end - Old insertion marker at the end
# Arguments:
#   file (string) filename to check
#######################################################################
function replace_old_markers {
  local -r file=$1

  sed -i "s/^${old_insertion_marker_begin}$/${insertion_marker_begin}/" "$file"
  sed -i "s/^${old_insertion_marker_end}$/${insertion_marker_end}/" "$file"
}

#######################################################################
# Function which prepares hacks for old versions of `terraform` and
# `terraform-docs` that them call `terraform_docs`
# Arguments:
#   hook_config (string with array) arguments that configure hook behavior
#   args (string with array) arguments that configure wrapped tool behavior
#   files (array) filenames to check
#######################################################################
function terraform_docs_ {
  local -r hook_config="$1"
  local -r args="$2"
  shift 2
  local -a -r files=("$@")

  # Get hook settings
  IFS=";" read -r -a configs <<< "$hook_config"

  local hack_terraform_docs
  local hack_terraform_docs=0
  if [[ $(\command -V terraform 2> /dev/null) ]]; then
    hack_terraform_docs=$(terraform version | sed -n 1p | grep -c 0.12) || true
  fi

  if [[ ! $(command -v terraform-docs) ]]; then
    echo "ERROR: terraform-docs is required by terraform_docs pre-commit hook but is not installed or in the system's PATH."
    exit 1
  fi

  local is_old_terraform_docs
  is_old_terraform_docs=$(terraform-docs version | grep -o "v0.[1-7]\." | tail -1) || true

  if [[ -z "$is_old_terraform_docs" ]]; then # Using terraform-docs 0.8+ (preferred)

    terraform_docs "0" "${configs[*]}" "$args" "${files[@]}"

  elif [[ "$hack_terraform_docs" == "1" ]]; then # Using awk script because terraform-docs is older than 0.8 and terraform 0.12 is used

    if [[ ! $(command -v awk) ]]; then
      echo "ERROR: awk is required for terraform-docs hack to work with Terraform 0.12."
      exit 1
    fi

    local tmp_file_awk
    tmp_file_awk=$(mktemp "${TMPDIR:-/tmp}/terraform-docs-XXXXXXXXXX")
    terraform_docs_awk "$tmp_file_awk"
    terraform_docs "$tmp_file_awk" "${configs[*]}" "$args" "${files[@]}"
    rm -f "$tmp_file_awk"

  else # Using terraform 0.11 and no awk script is needed for that

    terraform_docs "0" "${configs[*]}" "$args" "${files[@]}"

  fi
}

#######################################################################
# Wrapper around `terraform-docs` tool that check and change/create
# (depends on provided hook_config) terraform documentation in
# markdown format
# Arguments:
#   terraform_docs_awk_file (string) filename where awk hack for old
#     `terraform-docs` was written. Needed for TF 0.12+.
#     Hack skipped when `terraform_docs_awk_file == "0"`
#   hook_config (string with array) arguments that configure hook behavior
#   args (string with array) arguments that configure wrapped tool behavior
#   files (array) filenames to check
#######################################################################
function terraform_docs {
  local -r terraform_docs_awk_file="$1"
  local -r hook_config="$2"
  local args="$3"
  shift 3
  local -a -r files=("$@")

  local -a paths

  local index=0
  local file_with_path
  for file_with_path in "${files[@]}"; do
    file_with_path="${file_with_path// /__REPLACED__SPACE__}"

    paths[index]=$(dirname "$file_with_path")

    ((index += 1))
  done

  local -r tmp_file=$(mktemp)

  #
  # Get hook settings
  #
  local text_file="README.md"
  local use_path_to_file=false
  local add_to_existing=false
  local create_if_not_exist=false
  local use_standard_markers=true

  read -r -a configs <<< "$hook_config"

  for c in "${configs[@]}"; do

    IFS="=" read -r -a config <<< "$c"
    key=${config[0]}
    value=${config[1]}

    case $key in
      --path-to-file)
        text_file=$value
        use_path_to_file=true
        ;;
      --add-to-existing-file)
        add_to_existing=$value
        ;;
      --create-file-if-not-exist)
        create_if_not_exist=$value
        ;;
      --use-standard-markers)
        use_standard_markers=$value
        common::colorify "yellow" "WARNING: --use-standard-markers is deprecated and will be removed in the future."
        common::colorify "yellow" "         All needed changes already done by the hook, feel free to remove --use-standard-markers setting from your pre-commit config"
        ;;
    esac
  done

  if [[ $use_standard_markers == false ]]; then
    # update the insertion markers to those used by pre-commit-terraform before v1.93
    insertion_marker_begin="$old_insertion_marker_begin"
    insertion_marker_end="$old_insertion_marker_end"
  fi

  # Override formatter if no config file set
  if [[ "$args" != *"--config"* ]]; then
    local tf_docs_formatter="md"

  else

    local config_file=${args#*--config}
    config_file=${config_file#*=}
    config_file=${config_file% *}

    # Prioritize `.terraform-docs.yml` `output.file` over
    # `--hook-config=--path-to-file=` if it set
    local output_file
    # Get latest non-commented `output.file` from `.terraform-docs.yml`
    output_file=$(grep -A1000 -e '^output:$' "$config_file" | grep -E '^[[:space:]]+file:' | tail -n 1) || true

    if [[ $output_file ]]; then
      # Extract filename from `output.file` line
      output_file=$(echo "$output_file" | awk -F':' '{print $2}' | tr -d '[:space:]"' | tr -d "'")

      if [[ $use_path_to_file == true && "$output_file" != "$text_file" ]]; then
        common::colorify "yellow" "NOTE: You set both '--hook-config=--path-to-file=$text_file' and 'output.file: $output_file' in '$config_file'"
        common::colorify "yellow" "      'output.file' from '$config_file' will be used."
      fi

      text_file=$output_file
    fi

    # Suppress terraform_docs color
    local config_file_no_color
    config_file_no_color="$config_file$(date +%s).yml"

    if [ "$PRE_COMMIT_COLOR" = "never" ] &&
      [[ $(grep -e '^formatter:' "$config_file") == *"pretty"* ]] &&
      [[ $(grep '  color: ' "$config_file") != *"false"* ]]; then

      cp "$config_file" "$config_file_no_color"
      echo -e "settings:\n  color: false" >> "$config_file_no_color"
      args=${args/$config_file/$config_file_no_color}
    fi
  fi

  local dir_path
  for dir_path in $(echo "${paths[*]}" | tr ' ' '\n' | sort -u); do
    dir_path="${dir_path//__REPLACED__SPACE__/ }"

    pushd "$dir_path" > /dev/null || continue

    #
    # Create file if it not exist and `--create-if-not-exist=true` provided
    #
    if $create_if_not_exist && [[ ! -f "$text_file" ]]; then
      dir_have_tf_files="$(
        find . -maxdepth 1 -type f | sed 's|.*\.||' | sort -u | grep -oE '^tf$|^tfvars$' ||
          exit 0
      )"

      # if no TF files - skip dir
      [ ! "$dir_have_tf_files" ] && popd > /dev/null && continue

      dir="$(dirname "$text_file")"

      mkdir -p "$dir"

      # Use of insertion markers, where there is no existing README file
      {
        echo -e "# ${PWD##*/}\n"
        echo "$insertion_marker_begin"
        echo "$insertion_marker_end"
      } >> "$text_file"
    fi

    # If file still not exist - skip dir
    [[ ! -f "$text_file" ]] && popd > /dev/null && continue

    replace_old_markers "$text_file"

    #
    # If `--add-to-existing-file=true` set, check is in file exist "hook markers",
    # and if not - append "hook markers" to the end of file.
    #
    if $add_to_existing; then
      HAVE_MARKER=$(grep -o "$insertion_marker_begin" "$text_file" || exit 0)

      if [ ! "$HAVE_MARKER" ]; then
        # Use of insertion markers, where addToExisting=true, with no markers in the existing file
        echo "$insertion_marker_begin" >> "$text_file"
        echo "$insertion_marker_end" >> "$text_file"
      fi
    fi

    if [[ "$terraform_docs_awk_file" == "0" ]]; then
      # shellcheck disable=SC2086
      terraform-docs --output-file="" $tf_docs_formatter $args ./ > "$tmp_file"
    else
      # Can't append extension for mktemp, so renaming instead
      local tmp_file_docs
      tmp_file_docs=$(mktemp "${TMPDIR:-/tmp}/terraform-docs-XXXXXXXXXX")
      mv "$tmp_file_docs" "$tmp_file_docs.tf"
      local tmp_file_docs_tf
      tmp_file_docs_tf="$tmp_file_docs.tf"

      awk -f "$terraform_docs_awk_file" ./*.tf > "$tmp_file_docs_tf"
      # shellcheck disable=SC2086
      terraform-docs --output-file="" $tf_docs_formatter $args "$tmp_file_docs_tf" > "$tmp_file"
      rm -f "$tmp_file_docs_tf"
    fi

    # Use of insertion markers to insert the terraform-docs output between the markers
    # Replace content between markers with the placeholder - https://stackoverflow.com/questions/1212799/how-do-i-extract-lines-between-two-line-delimiters-in-perl#1212834
    perl_expression="if (/$insertion_marker_begin/../$insertion_marker_end/) { print \$_ if /$insertion_marker_begin/; print \"I_WANT_TO_BE_REPLACED\\n\$_\" if /$insertion_marker_end/;} else { print \$_ }"
    perl -i -ne "$perl_expression" "$text_file"

    # Replace placeholder with the content of the file
    perl -i -e 'open(F, "'"$tmp_file"'"); $f = join "", <F>; while(<>){if (/I_WANT_TO_BE_REPLACED/) {print $f} else {print $_};}' "$text_file"

    rm -f "$tmp_file"

    popd > /dev/null
  done

  # Cleanup
  rm -f "$config_file_no_color"
}

#######################################################################
# Function which creates file with `awk` hacks for old versions of
# `terraform-docs`
# Arguments:
#   output_file (string) filename where hack will be written to
#######################################################################
function terraform_docs_awk {
  local -r output_file=$1

  cat << "EOF" > "$output_file"
# This script converts Terraform 0.12 variables/outputs to something suitable for `terraform-docs`
# As of terraform-docs v0.6.0, HCL2 is not supported. This script is a *dirty hack* to get around it.
# https://github.com/terraform-docs/terraform-docs/
# https://github.com/terraform-docs/terraform-docs/issues/62
# Script was originally found here: https://github.com/cloudposse/build-harness/blob/master/bin/terraform-docs.awk
{
  if ( $0 ~ /\{/ ) {
    braceCnt++
  }
  if ( $0 ~ /\}/ ) {
    braceCnt--
  }
  # ----------------------------------------------------------------------------------------------
  # variable|output "..." {
  # ----------------------------------------------------------------------------------------------
  # [END] variable/output block
  if (blockCnt > 0 && blockTypeCnt == 0 && blockDefaultCnt == 0) {
    if (braceCnt == 0 && blockCnt > 0) {
      blockCnt--
      print $0
    }
  }
  # [START] variable or output block started
  if ($0 ~ /^[[:space:]]*(variable|output)[[:space:]][[:space:]]*"(.*?)"/) {
    # Normalize the braceCnt and block (should be 1 now)
    braceCnt = 1
    blockCnt = 1
    # [CLOSE] "default" and "type" block
    blockDefaultCnt = 0
    blockTypeCnt = 0
    # Print variable|output line
    print $0
  }
  # ----------------------------------------------------------------------------------------------
  # default = ...
  # ----------------------------------------------------------------------------------------------
  # [END] multiline "default" continues/ends
  if (blockCnt > 0 && blockTypeCnt == 0 && blockDefaultCnt > 0) {
      print $0
      # Count opening blocks
      blockDefaultCnt += gsub(/\(/, "")
      blockDefaultCnt += gsub(/\[/, "")
      blockDefaultCnt += gsub(/\{/, "")
      # Count closing blocks
      blockDefaultCnt -= gsub(/\)/, "")
      blockDefaultCnt -= gsub(/\]/, "")
      blockDefaultCnt -= gsub(/\}/, "")
  }
  # [START] multiline "default" statement started
  if (blockCnt > 0 && blockTypeCnt == 0 && blockDefaultCnt == 0) {
    if ($0 ~ /^[[:space:]][[:space:]]*(default)[[:space:]][[:space:]]*=/) {
      if ($3 ~ "null") {
        print "  default = \"null\""
      } else {
        print $0
        # Count opening blocks
        blockDefaultCnt += gsub(/\(/, "")
        blockDefaultCnt += gsub(/\[/, "")
        blockDefaultCnt += gsub(/\{/, "")
        # Count closing blocks
        blockDefaultCnt -= gsub(/\)/, "")
        blockDefaultCnt -= gsub(/\]/, "")
        blockDefaultCnt -= gsub(/\}/, "")
      }
    }
  }
  # ----------------------------------------------------------------------------------------------
  # type  = ...
  # ----------------------------------------------------------------------------------------------
  # [END] multiline "type" continues/ends
  if (blockCnt > 0 && blockTypeCnt > 0 && blockDefaultCnt == 0) {
    # The following 'print $0' would print multiline type definitions
    #print $0
    # Count opening blocks
    blockTypeCnt += gsub(/\(/, "")
    blockTypeCnt += gsub(/\[/, "")
    blockTypeCnt += gsub(/\{/, "")
    # Count closing blocks
    blockTypeCnt -= gsub(/\)/, "")
    blockTypeCnt -= gsub(/\]/, "")
    blockTypeCnt -= gsub(/\}/, "")
  }
  # [START] multiline "type" statement started
  if (blockCnt > 0 && blockTypeCnt == 0 && blockDefaultCnt == 0) {
    if ($0 ~ /^[[:space:]][[:space:]]*(type)[[:space:]][[:space:]]*=/ ) {
      if ($3 ~ "object") {
        print "  type = \"object\""
      } else {
        # Convert multiline stuff into single line
        if ($3 ~ /^[[:space:]]*list[[:space:]]*\([[:space:]]*$/) {
          type = "list"
        } else if ($3 ~ /^[[:space:]]*string[[:space:]]*\([[:space:]]*$/) {
          type = "string"
        } else if ($3 ~ /^[[:space:]]*map[[:space:]]*\([[:space:]]*$/) {
          type = "map"
        } else {
          type = $3
        }
        # legacy quoted types: "string", "list", and "map"
        if (type ~ /^[[:space:]]*"(.*?)"[[:space:]]*$/) {
          print "  type = " type
        } else {
          print "  type = \"" type "\""
        }
      }
      # Count opening blocks
      blockTypeCnt += gsub(/\(/, "")
      blockTypeCnt += gsub(/\[/, "")
      blockTypeCnt += gsub(/\{/, "")
      # Count closing blocks
      blockTypeCnt -= gsub(/\)/, "")
      blockTypeCnt -= gsub(/\]/, "")
      blockTypeCnt -= gsub(/\}/, "")
    }
  }
  # ----------------------------------------------------------------------------------------------
  # description = ...
  # ----------------------------------------------------------------------------------------------
  # [PRINT] single line "description"
  if (blockCnt > 0 && blockTypeCnt == 0 && blockDefaultCnt == 0) {
    if ($0 ~ /^[[:space:]][[:space:]]*description[[:space:]][[:space:]]*=/) {
      print $0
    }
  }
  # ----------------------------------------------------------------------------------------------
  # value = ...
  # ----------------------------------------------------------------------------------------------
  ## [PRINT] single line "value"
  #if (blockCnt > 0 && blockTypeCnt == 0 && blockDefaultCnt == 0) {
  #  if ($0 ~ /^[[:space:]][[:space:]]*value[[:space:]][[:space:]]*=/) {
  #    print $0
  #  }
  #}
  # ----------------------------------------------------------------------------------------------
  # Newlines, comments, everything else
  # ----------------------------------------------------------------------------------------------
  #if (blockTypeCnt == 0 && blockDefaultCnt == 0) {
  # Comments with '#'
  if ($0 ~ /^[[:space:]]*#/) {
    print $0
  }
  # Comments with '//'
  if ($0 ~ /^[[:space:]]*\/\//) {
    print $0
  }
  # Newlines
  if ($0 ~ /^[[:space:]]*$/) {
    print $0
  }
  #}
}
EOF

}

[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
