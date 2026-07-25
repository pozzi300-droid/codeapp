# C# Support for Code App

This fork adds native C# support to Code App using Mono runtime and Roslyn compiler.

## Features

- Compile and run `.cs` files directly on iPad
- No network required - everything runs locally
- JIT compilation via StikDebug for better performance
- Support for .csx script files

## Architecture

C# support is integrated using the same pattern as Java/Node.js:

1. **Mono.xcframework** - Native Mono runtime compiled for iOS arm64
2. **CSharp.swift** - App Extension launcher (runs in separate process)
3. **csharp.swift** - Command stubs for ios_system
4. **commandDictionary.plist** - Maps commands to Mono framework

## Commands

| Command | Description |
|---------|-------------|
| `csc file.cs` | Compile C# file to IL assembly |
| `csrun file.cs` | Compile and run C# file |
| `csx script.csx` | Run C# script file |
| `dotnet run` | Run .NET project (if available) |

## Building

### Prerequisites

- macOS with Xcode 15+
- GitHub account for Actions

### Build Workflow

1. Push to GitHub repository
2. Go to Actions tab
3. Run "Build Mono iOS" workflow
4. Run "Build IPA" workflow
5. Download the IPA artifact

### Local Build

```bash
# Clone the fork
git clone https://github.com/pozzi300-droid/codeapp.git
cd codeapp

# Download frameworks
./downloadFrameworks.sh

# Open in Xcode
open Code.xcworkspace
```

## Installation

### Via SideStore

1. Download the IPA from GitHub Actions artifacts
2. Open SideStore on your iPad
3. Connect iPad to computer
4. Import the IPA file
5. SideStore will resign and install it

### Enable JIT

Before running C# code, enable JIT via StikDebug:

1. Open StikDebug app
2. Connect iPad to computer via USB
3. Enable JIT for Code App
4. Launch Code App and run C# code

## Usage Examples

### Hello World

```csharp
// hello.cs
using System;

class Program
{
    static void Main()
    {
        Console.WriteLine("Hello from C# on iOS!");
    }
}
```

Run with:
```bash
csrun hello.cs
```

### Compile Only

```bash
csc hello.cs
mono hello.exe
```

### C# Script

```csharp
// script.csx
using System;
Console.WriteLine("Running script!");
```

Run with:
```bash
csx script.csx
```

## Troubleshooting

### "Mono framework not found"

Ensure Mono.xcframework is in the Frameworks directory. Rebuild if necessary.

### JIT not available

Make sure StikDebug is enabled before launching Code App.

### Compilation errors

Check that your C# code uses only APIs available in the Mono BCL. Some .NET Core APIs may not be available.

## Limitations

- No GUI support (console only)
- Limited BCL - not all System.* assemblies are included
- No NuGet package restore
- Some .NET Core APIs may not work

## Future Improvements

- Add more BCL assemblies
- Support for NuGet packages
- Add MonoDevelop language service
- Support for .csproj projects
