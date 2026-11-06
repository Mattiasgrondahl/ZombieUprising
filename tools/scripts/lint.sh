#!/usr/bin/env bash
# Strict Luau analysis gate.
#
# luau-analyze (0.745, shipped without a Roblox API dump) cannot resolve Roblox
# globals like Vector3/Color3/Enum/Instance/game, so those specific "Unknown
# global"/"Unknown type" notices are expected environmental noise. We filter
# ONLY those against an explicit allowlist, and fail on everything else so real
# type errors, syntax errors, and genuine typos still break the build.
set -euo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
ANALYZE="$BIN/luau-analyze"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$ROOT"

FILES=$(find src -name '*.luau' -o -name '*.lua' | sort)
if [[ -z "$FILES" ]]; then
  echo "no sources found"
  exit 1
fi

ALLOW='Vector3|CFrame|Color3|UDim2|UDim|Vector2|Enum|Instance|game|workspace|script|RaycastParams|RaycastResult|NumberRange|NumberSequence|ColorSequence|BrickColor|Region3|TweenInfo|Folder|RemoteEvent|RemoteFunction|Part|MeshPart|Model|Script|LocalScript|ModuleScript|Humanoid|Player|Players|TextLabel|TextButton|Frame|ScreenGui|BillboardGui|ImageLabel|ImageButton|ScrollingFrame|UIListLayout|UIPadding|UICorner|UIStroke|UIGradient|Highlight|Tool|Camera|RunService|TweenService|PathfindingService|DataStoreService|ReplicatedStorage|ServerScriptService|StarterGui|StarterPlayer|Workspace|Lighting|SoundService|HttpService|CollectionService|Debris|MarketplaceService|BadgeService|MemoryStoreService|MessagingService|PhysicsService|ContextActionService|UserInputService|GuiService|TeleportService|Sound|ParticleEmitter|PointLight|SpotLight|Attachment|Beam|NumberValue|StringValue|BoolValue|ObjectValue|IntValue|Atmosphere|Sky|BloomEffect|ColorCorrectionEffect|BlurEffect|Animation|Animator|Explosion|Fire|Smoke|Trail|VectorForce|BodyVelocity|AlignPosition|WeldConstraint|Motor6D|Terrain|Team|Teams|ServiceProvider|DataModel|LuaSourceContainer|BasePart|PVInstance|GuiObject|GuiBase2d|GuiBase|LayerCollector|ValueBase|Instance|tick|elapsedTime|warn|typeof|task|table|string|math|os|coroutine|Random|shared|_G|DateTime|buffer|bit32|utf8|debug|select|pcall|error|assert|setmetatable|getmetatable|ipairs|pairs|next|tonumber|tostring|unpack|require|print'

# Run analysis, capture output (analyzer may exit non-zero when it finds issues)
set +e
OUT=$("$ANALYZE" --mode=strict $FILES 2>&1)
set -e

# Keep only lines that are NOT an allowlisted unknown-global/type notice.
BAD=$(echo "$OUT" | grep -vE ": (Unknown global '($ALLOW)'|Unknown type '($ALLOW)'|Unknown require: unsupported path)" || true)

if [[ -n "$BAD" ]]; then
  echo "LINT FAILURES:"
  echo "$BAD"
  exit 1
fi

echo "lint OK (strict) -- $(echo "$FILES" | wc -l) files"
