IOS_SDK ?= iphoneos
SIMULATOR_SDK ?= iphonesimulator
CONFIGURATION ?= Release
LIPO ?= `xcrun -find lipo -sdk $(IOS_SDK)`
OUTPUT ?= ./out/$(CONFIGURATION)/libispdy-combined.a

all:
	mkdir -p out/$(CONFIGURATION)
	./gyp_ispdy -f xcode -Dsdk=$(IOS_SDK) --suffix=-ios
	xcodebuild -configuration $(CONFIGURATION) -project ispdy-ios.xcodeproj
	./gyp_ispdy -f xcode -Dsdk=$(SIMULATOR_SDK) --suffix=-sim
	xcodebuild -configuration $(CONFIGURATION) -project ispdy-sim.xcodeproj
	$(LIPO) -create \
			./build/$(CONFIGURATION)-iphoneos/libispdy-bundled.a \
			./build/$(CONFIGURATION)-iphonesimulator/libispdy-bundled.a \
			-output $(OUTPUT)

clean:
	xcodebuild clean -configuration Release -project ispdy-ios.xcodeproj
	xcodebuild clean -configuration Release -project ispdy-sim.xcodeproj
	xcodebuild clean -configuration Debug -project ispdy-ios.xcodeproj
	xcodebuild clean -configuration Debug -project ispdy-sim.xcodeproj
	rm -f $(OUTPUT) \
			./build/Debug-iphoneos/libispdy-bundled.a \
			./build/Debug-iphonesimulator/libispdy-bundled.a \
			./build/Release-iphoneos/libispdy-bundled.a \
			./build/Release-iphonesimulator/libispdy-bundled.a \

.PHONY: all clean
