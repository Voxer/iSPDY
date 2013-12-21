IOS_SDK ?= iphoneos
SIMULATOR_SDK ?= iphonesimulator
CONFIGURATION ?= Release
LIPO ?= `xcrun -find lipo -sdk $(IOS_SDK)`
OUTPUT ?= ./out/$(CONFIGURATION)/libispdy-combined.a

CONFIGURATIONS = Debug Release
SUFFIXES = iphoneos iphonesimulator macosx

all: xcodeproj
	mkdir -p out/$(CONFIGURATION)
	for suffix in $(SUFFIXES) ; do \
		xcodebuild -configuration $(CONFIGURATION) \
			-project ispdy-$$suffix.xcodeproj ; \
	done
	$(LIPO) -create \
			./build/$(CONFIGURATION)-iphoneos/libispdy-bundled.a \
			./build/$(CONFIGURATION)-iphonesimulator/libispdy-bundled.a \
			-output $(OUTPUT)

xcodeproj:
	./gyp_ispdy -f xcode -Dsdk=$(IOS_SDK) --suffix=-iphoneos
	./gyp_ispdy -f xcode -Dsdk=$(SIMULATOR_SDK) --suffix=-iphonesimulator
	./gyp_ispdy -f xcode --suffix=-macosx

clean:
	for config in $(CONFIGURATIONS) ; do \
		for suffix in $(SUFFIXES) ; do \
			xcodebuild clean -configuration $$config \
				-project ispdy-$$suffix.xcodeproj ;\
			rm -rf ./build/$$config-$$suffix/libispdy-bundled.a ;\
		done \
	done
	rm -f $(OUTPUT)

.PHONY: all clean xcodeproj
