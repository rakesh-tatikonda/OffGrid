#!/bin/bash
set -e

echo "Running ThirdParty submodule fixes..."

# 1. Strip nested Package.swift files 
# Prevents XcodeGen and SPM from getting confused by nested packages.
echo "Removing nested Package.swift files..."
rm -f ThirdParty/whisper.cpp/Package.swift
rm -f ThirdParty/llama.cpp/Package.swift

# 2. Strip CLI entry points
# SPM will automatically flag a target as an "executable" instead of a "library" 
# if it finds any main.* files. We must delete them all.
echo "Removing CLI executables to force Library targets..."

find ThirdParty/whisper.cpp -name "main.swift" -type f -delete
find ThirdParty/whisper.cpp -name "main.cpp" -type f -delete
find ThirdParty/whisper.cpp -name "main.c" -type f -delete

find ThirdParty/llama.cpp -name "main.swift" -type f -delete
find ThirdParty/llama.cpp -name "main.cpp" -type f -delete
find ThirdParty/llama.cpp -name "main.c" -type f -delete

echo "ThirdParty submodule fixes applied successfully!"
