.PHONY: all build clean help

# FVAIOS Makefile

all: build

build:
	@echo "Building FVAIOS ISO..."
	@sudo ./build.sh

clean:
	@echo "Cleaning build directory..."
	@rm -rf work build

help:
	@echo "FVAIOS Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all    - Build the ISO (default)"
	@echo "  build  - Build the ISO"
	@echo "  clean  - Remove build artifacts"
	@echo "  help   - Show this help"
	@echo ""
	@echo "Usage:"
	@echo "  make        # Build the ISO"
	@echo "  make clean  # Clean build directory"
