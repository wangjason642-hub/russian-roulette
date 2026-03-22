#!/usr/bin/env bash
# deploy.sh — versioned static deploy to GCS
set -euo pipefail

BUCKET="${1:-russian-roulette-game}"
PROJECT="fengs-vpn"
REGION="us-central1"

echo "🚀 Deploying to gs://${BUCKET} (project: ${PROJECT})"

# ── 1. Ensure bucket exists ──────────────────────────────────────────────────
if ! gcloud storage buckets describe "gs://${BUCKET}" --project="${PROJECT}" &>/dev/null; then
  echo "📦 Creating bucket gs://${BUCKET}..."
  gcloud storage buckets create "gs://${BUCKET}" \
    --project="${PROJECT}" \
    --location="${REGION}" \
    --uniform-bucket-level-access
  gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
    --member="allUsers" \
    --role="roles/storage.objectViewer"
  gcloud storage buckets update "gs://${BUCKET}" \
    --web-main-page-suffix=index.html \
    --web-error-page=index.html
  echo "✅ Bucket created and configured"
else
  echo "✅ Bucket exists"
fi

# ── 2. Hash helper (works on macOS and Linux) ────────────────────────────────
hash_file() {
  openssl dgst -md5 "$1" | awk '{print $NF}' | cut -c1-8
}

# ── 3. Upload versioned asset, print filename ────────────────────────────────
upload_asset() {
  local src="$1"       # relative to src/
  local content_type="$2"
  local ext="${src##*.}"
  local base="${src%.*}"
  local hash
  hash=$(hash_file "src/${src}")
  local versioned="${base}.${hash}.${ext}"

  echo "  ↑ ${src} → ${versioned}" >&2
  gcloud storage cp "src/${src}" "gs://${BUCKET}/${versioned}" \
    --cache-control="public, max-age=31536000, immutable" \
    --content-type="${content_type}" >/dev/null
  echo "${versioned}"
}

echo ""
echo "📁 Uploading versioned assets..."
CSS_FILE=$(upload_asset  "game.css"      "text/css")
JS_FILE=$(upload_asset   "game.js"       "application/javascript")
WEBP_FILE=$(upload_asset "revolver.webp" "image/webp")
PNG_FILE=$(upload_asset  "revolver.png"  "image/png")

# ── 4. Rewrite index.html with hashed references ────────────────────────────
echo ""
echo "📝 Building dist/index.html with versioned references..."
mkdir -p dist

python3 -c "
import re, sys

bucket    = sys.argv[1]
css_file  = sys.argv[2]
js_file   = sys.argv[3]
webp_file = sys.argv[4]
png_file  = sys.argv[5]

with open('index.html') as f:
    html = f.read()

# Replace inline <style>...</style> with <link>
base = 'https://storage.googleapis.com/' + bucket + '/'

html = re.sub(
    r'<style>.*?</style>',
    '<link rel=\"stylesheet\" href=\"' + base + css_file + '\">',
    html, flags=re.DOTALL
)

# Replace inline <script>...</script> (not CDN) with external <script src>
html = re.sub(
    r'<script>.*?</script>',
    '<script src=\"' + base + js_file + '\"></script>',
    html, flags=re.DOTALL
)

# Replace image references
html = html.replace('revolver.webp', base + webp_file)
html = html.replace('revolver.png',  base + png_file)

with open('dist/index.html', 'w') as f:
    f.write(html)
print('  ✅ dist/index.html written')
" "$BUCKET" "$CSS_FILE" "$JS_FILE" "$WEBP_FILE" "$PNG_FILE"

# ── 5. Upload index.html with no-cache ───────────────────────────────────────
echo ""
echo "📄 Uploading index.html (no-cache)..."
gcloud storage cp "dist/index.html" "gs://${BUCKET}/index.html" \
  --cache-control="no-cache, no-store, must-revalidate" \
  --content-type="text/html; charset=utf-8"

# ── 6. Done ──────────────────────────────────────────────────────────────────
echo ""
echo "✅ Deploy complete!"
echo "🌐 https://storage.googleapis.com/${BUCKET}/index.html"
