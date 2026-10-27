# Если стоит полный Xcode — берём его SDK (нужен для SwiftUI .glassEffect), не трогая xcode-select.
ifneq ($(wildcard /Applications/Xcode.app/Contents/Developer),)
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
endif
SWIFTC ?= xcrun swiftc
SDKMAJOR := $(shell xcrun --sdk macosx --show-sdk-version 2>/dev/null | cut -d. -f1)
GLASS  := $(shell [ "$(SDKMAJOR)" -ge 26 ] 2>/dev/null && echo -DSYSTEM_GLASS)
# Постоянная подпись своим сертификатом: «Универсальный доступ» не слетает после пересборки.
SIGN   := $(shell security find-identity -p codesigning 2>/dev/null | grep -q '"RingTab Dev"' && echo "RingTab Dev" || echo -)
FLAGS  = -O -swift-version 5 -suppress-warnings
APP    = build/Rondo.app
SRC    = src/model.swift src/settings.swift src/overlay.swift src/glass.swift src/settingsui.swift src/main.swift

all: $(APP) build/ringtest

$(APP): $(SRC) Info.plist res/AppIcon.icns $(wildcard res/backdrops/*)
	@mkdir -p $(APP)/Contents/MacOS
	@echo "SDK macOS $(SDKMAJOR)$(if $(GLASS), — SwiftUI Liquid Glass включён, — без SwiftUI-стекла)"
	$(SWIFTC) $(FLAGS) $(GLASS) -o $(APP)/Contents/MacOS/Rondo $(SRC)
	cp Info.plist $(APP)/Contents/Info.plist
	rm -rf $(APP)/Contents/Resources/backdrops && mkdir -p $(APP)/Contents/Resources && cp -R res/backdrops $(APP)/Contents/Resources/backdrops
	cp res/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	codesign --force -s "$(SIGN)" --identifier com.morphine.ringtab $(APP)

build/ringtest: src/model.swift src/settings.swift src/test/main.swift
	@mkdir -p build
	$(SWIFTC) $(FLAGS) -o $@ $^

test: build/ringtest
	./build/ringtest

# картинка круга без перехвата клавиш (для проверки внешнего вида)
demo: $(APP)
	$(APP)/Contents/MacOS/Rondo --demo build/demo.png

# запуск как приложения: разрешение «Универсальный доступ» выдаётся самому Rondo
run: $(APP)
	open $(APP)

# запуск в терминале с логом: разрешение нужно терминалу
cli: $(APP)
	$(APP)/Contents/MacOS/Rondo --cli -v

clean:
	rm -rf build

.PHONY: all test demo run cli clean dmg

# иконка из исходника рисунка: tools/logo.swift → res/AppIcon.icns
icon:
	swiftc -O tools/logo.swift -o build/logo
	rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
	for s in 16 32 128 256 512; do d=$$((s*2)); SZ=$$s SPEC=clay,1,8,0 build/logo build/AppIcon.iconset/icon_$${s}x$${s}.png; SZ=$$d SPEC=clay,1,8,0 build/logo build/AppIcon.iconset/icon_$${s}x$${s}@2x.png; done
	iconutil -c icns build/AppIcon.iconset -o res/AppIcon.icns

# установщик: build/Rondo-<версия>.dmg
dmg: $(APP)
	tools/make-dmg.sh
