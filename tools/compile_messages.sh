#!/bin/bash
# SPDX-FileCopyrightText: 2023 Alexandra Stone <alexankitty@gmail.com>
# SPDX-FileCopyrightText: 2025-2026 Vitaliy Elin <daydve@smbit.pro>
# SPDX-License-Identifier: GPL-2.0-or-later
# Version: 8 (Modular)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/functions.sh"

PACKAGE_DIR="$(readlink -f "${SCRIPT_DIR}/../package")"
METADATA_FILE="${PACKAGE_DIR}/metadata.json"
TRANSLATE_DIR="${SCRIPT_DIR}/translate"

cd "${TRANSLATE_DIR}"

plasmoidName=$(get_metadata "Id" "${METADATA_FILE}")
projectName="plasma_applet_${plasmoidName}"

if [ -z "$plasmoidName" ]; then
    log_error "Couldn't read 'Id' from metadata.json."
    exit 1
fi

if ! command -v msgfmt &> /dev/null; then
    log_error "msgfmt command not found. Need to install gettext."
    log_info "Running 'sudo apt install gettext'"
    sudo apt install gettext
fi

log_info "Compiling messages for ${projectName}"

rm -rf "${PACKAGE_DIR}/contents/locale"

declare -A locale_catalogs

# Merge catalogs from tools/translate/languages and package/translate.
# Prefer the first catalog seen for each locale to keep builds deterministic.
while IFS= read -r -d '' cat; do
    catLocale=$(basename "${cat%.*}")
    if [ -n "${locale_catalogs[$catLocale]-}" ]; then
        log_info "Skipping duplicate locale '${catLocale}' from '${cat}' (using '${locale_catalogs[$catLocale]}')."
        continue
    fi
    locale_catalogs[$catLocale]="$cat"
done < <(find "${TRANSLATE_DIR}/languages" "${PACKAGE_DIR}/translate" -type f -name '*.po' -print0 2>/dev/null || true)

if [ "${#locale_catalogs[@]}" -gt 0 ]; then
    mapfile -t sorted_locales < <(printf '%s\n' "${!locale_catalogs[@]}" | sort)

    for catLocale in "${sorted_locales[@]}"; do
        cat="${locale_catalogs[$catLocale]}"

        log_info "${cat}"
        msgfmt -o "${catLocale}.mo" "$cat"

        installPath="${PACKAGE_DIR}/contents/locale/${catLocale}/LC_MESSAGES/${projectName}.mo"

        log_info "Install to ${installPath}"
        mkdir -p "$(dirname "$installPath")"
        mv "${catLocale}.mo" "${installPath}"
    done
fi

log_success "Done building messages"
