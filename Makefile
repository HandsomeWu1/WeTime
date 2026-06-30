APP_NAME    := WeTime
BUNDLE_ID   := com.hansonwu.wetime
APP_DIR     := $(APP_NAME).app
ZIP_FILE    := $(APP_NAME).zip

# 版本号：发布时用 `make release VERSION=1.0.1`
VERSION     ?= 1.0.0

# GitHub
GH_OWNER    := HandsomeWu1
GH_REPO     := WeTime

# 源文件
SWIFT_SRC   := main.swift
RAW_ICON    := icon_raw.png
POLISHED    := icon.png
ICNS        := AppIcon.icns

.PHONY: all build run icon clean polish open zip release tag

all: build

# ---- 1. 处理图标 ----
$(POLISHED): $(RAW_ICON) icon_polish.swift
	swift icon_polish.swift $(RAW_ICON) $(POLISHED)

polish: $(POLISHED)

# ---- 2. 生成 .icns ----
$(ICNS): $(POLISHED)
	@rm -rf AppIcon.iconset
	@mkdir AppIcon.iconset
	sips -z 16 16     $(POLISHED) --out AppIcon.iconset/icon_16x16.png        >/dev/null
	sips -z 32 32     $(POLISHED) --out AppIcon.iconset/icon_16x16@2x.png     >/dev/null
	sips -z 32 32     $(POLISHED) --out AppIcon.iconset/icon_32x32.png        >/dev/null
	sips -z 64 64     $(POLISHED) --out AppIcon.iconset/icon_32x32@2x.png     >/dev/null
	sips -z 128 128   $(POLISHED) --out AppIcon.iconset/icon_128x128.png      >/dev/null
	sips -z 256 256   $(POLISHED) --out AppIcon.iconset/icon_128x128@2x.png   >/dev/null
	sips -z 256 256   $(POLISHED) --out AppIcon.iconset/icon_256x256.png      >/dev/null
	sips -z 512 512   $(POLISHED) --out AppIcon.iconset/icon_256x256@2x.png   >/dev/null
	sips -z 512 512   $(POLISHED) --out AppIcon.iconset/icon_512x512.png      >/dev/null
	cp $(POLISHED)                AppIcon.iconset/icon_512x512@2x.png
	iconutil -c icns AppIcon.iconset -o $(ICNS)
	@rm -rf AppIcon.iconset

icon: $(ICNS)

# ---- 3. 打包 .app ----
build: $(ICNS)
	@rm -rf $(APP_DIR)
	@mkdir -p $(APP_DIR)/Contents/MacOS
	@mkdir -p $(APP_DIR)/Contents/Resources
	swiftc -O $(SWIFT_SRC) -o $(APP_DIR)/Contents/MacOS/$(APP_NAME)
	cp $(ICNS) $(APP_DIR)/Contents/Resources/
	@printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '<key>CFBundleName</key><string>$(APP_NAME)</string>' \
	  '<key>CFBundleDisplayName</key><string>$(APP_NAME)</string>' \
	  '<key>CFBundleIdentifier</key><string>$(BUNDLE_ID)</string>' \
	  '<key>CFBundleVersion</key><string>$(VERSION)</string>' \
	  '<key>CFBundleShortVersionString</key><string>$(VERSION)</string>' \
	  '<key>CFBundleExecutable</key><string>$(APP_NAME)</string>' \
	  '<key>CFBundlePackageType</key><string>APPL</string>' \
	  '<key>LSMinimumSystemVersion</key><string>11.0</string>' \
	  '<key>LSUIElement</key><true/>' \
	  '<key>CFBundleIconFile</key><string>AppIcon</string>' \
	  '</dict></plist>' \
	  > $(APP_DIR)/Contents/Info.plist
	codesign --force --deep --sign - $(APP_DIR)
	@echo "✅ 打包完成: $(APP_DIR) (v$(VERSION))"

# ---- 4. 便捷命令 ----
run: build
	./$(APP_DIR)/Contents/MacOS/$(APP_NAME)

open: build
	open $(APP_DIR)

zip: build
	@rm -f $(ZIP_FILE)
	@xattr -cr $(APP_DIR)
	ditto -c -k --sequesterRsrc --keepParent $(APP_DIR) $(ZIP_FILE)
	@echo "✅ 压缩完成: $(ZIP_FILE)"

# ---- 5. 一键发布到 GitHub ----
# 用法: make release VERSION=1.0.1 NOTES="新增 xxx 功能"
NOTES ?= See CHANGELOG.
release: zip
	@which gh > /dev/null || (echo "❌ 需要先安装 GitHub CLI: brew install gh"; exit 1)
	@gh auth status > /dev/null 2>&1 || (echo "❌ 请先 gh auth login"; exit 1)
	@echo "📦 创建 v$(VERSION) release..."
	gh release create v$(VERSION) $(ZIP_FILE) \
	  --repo $(GH_OWNER)/$(GH_REPO) \
	  --title "v$(VERSION)" \
	  --notes "$(NOTES)"
	@echo "✅ 发布完成: https://github.com/$(GH_OWNER)/$(GH_REPO)/releases/tag/v$(VERSION)"

clean:
	rm -rf $(APP_DIR) $(ICNS) $(POLISHED) AppIcon.iconset $(ZIP_FILE)
