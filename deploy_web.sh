#!/usr/bin/env bash
set -e

# Ensure ~/.local/bin and npx are in PATH
export PATH="$HOME/.local/bin:$PATH"

echo "=========================================="
echo " 🚀 RoadSense Web Deployment Pipeline"
echo "=========================================="

echo "📦 Step 1: Compiling Web Release Bundle..."
flutter build web --release --target lib/web_main.dart

echo ""
echo "☁️  Step 2: Deploying to Firebase Hosting & Rules..."
npx -y firebase-tools deploy --only hosting,firestore:rules

echo ""
echo "✅ Deployment Successful!"
echo "🌐 Live URL: https://pothole-app-b277b.web.app"
echo "🌐 Custom Domain: https://roadsense.me"
echo "=========================================="
