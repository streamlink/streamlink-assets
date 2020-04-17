#!/usr/bin/env bash
set -e

for var in GITHUB_ACTIONS GITHUB_REPOSITORY; do
    [[ -z "${!var}" ]] && { echo >&2 "Missing ${var} env var"; exit 1; }
done

DATA="data.json"
FILES=()

GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPOSITORY}"
GITHUB_API_HEADERS=(
    -H "Accept: application/vnd.github.v3+json"
    -H "User-Agent: ${GITHUB_REPOSITORY}"
    -H "Authorization: token ${RELEASES_API_KEY}"
)


ROOT="$(git rev-parse --show-toplevel)"
TEMP=$(mktemp -d) && trap "rm -rf ${TEMP}" EXIT || exit 255
cd "${TEMP}"


while IFS=" " read -r url checksum filename; do
    echo "Downloading ${filename}"
    curl -s -L --output "${filename}" "${url}"
    echo "Comparing checksums"
    echo "${checksum} ${filename}" | sha256sum --check -
    FILES+=("${filename}")
done < <(jq -r '.[] | "\(.url) \(.checksum) \(.filename)"' "${ROOT}/${DATA}")


[[ "${GITHUB_REF}" =~ ^refs/tags/.+ ]] || { echo -e "Not a release, aborting\n\nDone"; exit 0; }
[[ -z "${RELEASES_API_KEY}" ]] && { echo >&2 "Missing RELEASES_API_KEY env var"; exit 1; }


TAG_NAME="${GITHUB_REF#refs/tags/}"

echo "Checking for existing release on tag: ${TAG_NAME}"
RELEASE_ID=$(curl -s \
    -X GET \
    "${GITHUB_API_HEADERS[@]}" \
    "${GITHUB_API_URL}/releases/tags/${TAG_NAME}" \
    | jq -r ".id | select(. != null)"
)

if [[ -n "${RELEASE_ID}" ]]; then
    echo "Release found: ${RELEASE_ID}"
else
    RELEASE_ID=$(curl -s \
        -X POST \
        "${GITHUB_API_HEADERS[@]}" \
        -d "{\"tag_name\":\"${TAG_NAME}\",\"name\":\"${TAG_NAME}\"}" \
        "${GITHUB_API_URL}/releases" \
        | jq -r ".id | select(. != null)"
    )
    if [[ -z "${RELEASE_ID}" ]]; then
        echo >&2 "Could not create new release"
        exit 1
    fi
    echo "New release created: ${RELEASE_ID}"
fi

for file in "${FILES[@]}"; do
    echo "Uploading release asset: ${file}"
    curl -s \
        -X POST \
        "${GITHUB_API_HEADERS[@]}" \
        -H "Content-Type: application/octet-stream" \
        -H "Content-Length: $(stat --printf="%s" "${file}")" \
        --data-binary "@${file}" \
        "https://uploads.github.com/repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}/assets?name=${file}" \
        > /dev/null
done


echo -e "\nDone"
