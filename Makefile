.PHONY: setup project test clean

# Generate Xcode project and open it
setup: project
	open ReticulumMessenger.xcodeproj

# Generate Xcode project using XcodeGen
project:
	@which xcodegen > /dev/null 2>&1 || (echo "Installing XcodeGen..." && brew install xcodegen)
	xcodegen generate
	@echo "✓ Xcode project generated successfully"

# Run package tests
test:
	cd Packages/ReticulumKit && swift test

# Clean build artifacts
clean:
	rm -rf DerivedData build
	rm -rf Packages/ReticulumKit/.build
	rm -rf *.xcodeproj *.xcworkspace
	@echo "✓ Cleaned build artifacts"

# Build the package library only
build-lib:
	cd Packages/ReticulumKit && swift build

# Format Swift code (requires swift-format)
format:
	@which swift-format > /dev/null 2>&1 || (echo "Installing swift-format..." && brew install swift-format)
	find . -name "*.swift" -not -path "./.build/*" -not -path "*/DerivedData/*" | xargs swift-format -i

# Lint Swift code
lint:
	@which swiftlint > /dev/null 2>&1 || (echo "Installing SwiftLint..." && brew install swiftlint)
	swiftlint
