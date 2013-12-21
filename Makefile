IOS_SDK ?= iphoneos
SIMULATOR_SDK ?= iphonesimulator
CONFIGURATION ?= Release
LIPO ?= `xcrun -find lipo -sdk $(IOS_SDK)`
OUTPUT ?= ./out/$(CONFIGURATION)/libispdy-combined.a

all:
	mkdir -p out/$(CONFIGURATION)
	./gyp_ispdy -f xcode -Dsdk=$(IOS_SDK) --suffix=-iphoneos
	xcodebuild -configuration $(CONFIGURATION) -project ispdy-iphoneos.xcodeproj
	./gyp_ispdy -f xcode -Dsdk=$(SIMULATOR_SDK) --suffix=-iphonesimulator
	xcodebuild -configuration $(CONFIGURATION) -project ispdy-iphonesimulator.xcodeproj
	$(LIPO) -create \
			./build/$(CONFIGURATION)-iphoneos/libispdy-bundled.a \
			./build/$(CONFIGURATION)-iphonesimulator/libispdy-bundled.a \
			-output $(OUTPUT)

clean:
	xcodebuild clean -configuration Release -project ispdy-iphoneos.xcodeproj
	xcodebuild clean -configuration Release -project ispdy-iphonesimulator.xcodeproj
	xcodebuild clean -configuration Debug -project ispdy-iphoneos.xcodeproj
	xcodebuild clean -configuration Debug -project ispdy-iphonesimulator.xcodeproj
	rm -f $(OUTPUT) \
			./build/Debug-iphoneos/libispdy-bundled.a \
			./build/Debug-iphonesimulator/libispdy-bundled.a \
			./build/Release-iphoneos/libispdy-bundled.a \
			./build/Release-iphonesimulator/libispdy-bundled.a \

.PHONY: all clean
