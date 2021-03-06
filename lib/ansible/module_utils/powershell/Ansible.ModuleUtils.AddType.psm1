# Copyright (c) 2018 Ansible Project
# Simplified BSD License (see licenses/simplified_bsd.txt or https://opensource.org/licenses/BSD-2-Clause)

Function Add-CSharpType {
    <#
    .SYNOPSIS
    Compiles one or more C# scripts similar to Add-Type. This exposes
    more configuration options that are useable within Ansible and it
    also allows multiple C# sources to be compiled together.

    .PARAMETER References
    [String[]] A collection of C# scripts to compile together.

    .PARAMETER IgnoreWarnings
    [Switch] Whether to compile code that contains compiler warnings, by
    default warnings will cause a compiler error.

    .PARAMETER PassThru
    [Switch] Whether to return the loaded Assembly

    .PARAMETER AnsibleModule
    TODO - This is an AnsibleModule object that is used to derive the
    TempPath and Debug values.
        TempPath is set to the TmpDir property of the class
        IncludeDebugInfo is set when the Ansible verbosity is >= 3

    .PARAMETER TempPath
    [String] The temporary directory in which the dynamic assembly is
    compiled to. This file is deleted once compilation is complete.
    Cannot be used when AnsibleModule is set. This is a no-op when
    running on PSCore.

    .PARAMETER IncludeDebugInfo
    [Switch] Whether to include debug information in the compiled
    assembly. Cannot be used when AnsibleModule is set. This is a no-op
    when running on PSCore.
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][String[]]$References,
        [Switch]$IgnoreWarnings,
        [Switch]$PassThru,
        [Parameter(Mandatory=$true, ParameterSetName="Module")][Object]$AnsibleModule,
        [Parameter(ParameterSetName="Manual")][String]$TempPath = $env:TMP,
        [Parameter(ParameterSetName="Manual")][Switch]$IncludeDebugInfo
    )
    if ($null -eq $References -or $References.Length -eq 0) {
        return
    }

    # define special symbols CORECLR, WINDOWS, UNIX if required
    # the Is* variables are defined on PSCore, if absent we assume an
    # older version of PowerShell under .NET Framework and Windows
    $defined_symbols = [System.Collections.ArrayList]@()
    $is_coreclr = Get-Variable -Name IsCoreCLR -ErrorAction SilentlyContinue
    if ($null -ne $is_coreclr) {
        if ($is_coreclr.Value) {
            $defined_symbols.Add("CORECLR") > $null
        }
    }
    $is_windows = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
    if ($null -ne $is_windows) {
        if ($is_windows.Value) {
            $defined_symbols.Add("WINDOWS") > $null
        } else {
            $defined_symbols.Add("UNIX") > $null
        }
    } else {
        $defined_symbols.Add("WINDOWS") > $null
    }

    # pattern used to find referenced assemblies in the code
    $assembly_pattern = "^//\s*AssemblyReference\s+-Name\s+(?<Name>[\w.]*)(\s+-CLR\s+(?<CLR>Core|Framework))?$"
    $no_warn_pattern = "^//\s*NoWarn\s+-Name\s+(?<Name>[\w\d]*)(\s+-CLR\s+(?<CLR>Core|Framework))?$"

    # PSCore vs PSDesktop use different methods to compile the code,
    # PSCore uses Roslyn and can compile the code purely in memory
    # without touching the disk while PSDesktop uses CodeDom and csc.exe
    # to compile the code. We branch out here and run each
    # distribution's method to add our C# code.
    if ($is_coreclr) {
        # compile the code using Roslyn on PSCore

        # Include the default assemblies using the logic in Add-Type
        # https://github.com/PowerShell/PowerShell/blob/master/src/Microsoft.PowerShell.Commands.Utility/commands/utility/AddType.cs
        $assemblies = [System.Collections.Generic.HashSet`1[Microsoft.CodeAnalysis.MetadataReference]]@(
            [Microsoft.CodeAnalysis.CompilationReference]::CreateFromFile(([System.Reflection.Assembly]::GetAssembly([PSObject])).Location)
        )
        $netcore_app_ref_folder = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName([PSObject].Assembly.Location), "ref")
        $lib_assembly_location = [System.IO.Path]::GetDirectoryName([object].Assembly.Location)
        foreach ($file in [System.IO.Directory]::EnumerateFiles($netcore_app_ref_folder, "*.dll", [System.IO.SearchOption]::TopDirectoryOnly)) {
            $assemblies.Add([Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile($file)) > $null
        }

        # loop through the references, parse as a SyntaxTree and get
        # referenced assemblies
        $ignore_warnings = New-Object -TypeName 'System.Collections.Generic.Dictionary`2[[String], [Microsoft.CodeAnalysis.ReportDiagnostic]]'
        $parse_options = ([Microsoft.CodeAnalysis.CSharp.CSharpParseOptions]::Default).WithPreprocessorSymbols($defined_symbols)
        $syntax_trees = [System.Collections.Generic.List`1[Microsoft.CodeAnalysis.SyntaxTree]]@()
        foreach ($reference in $References) {
            # scan through code and add any assemblies that match
            # //AssemblyReference -Name ... [-CLR Core]
            $sr = New-Object -TypeName System.IO.StringReader -ArgumentList $reference
            try {
                while ($null -ne ($line = $sr.ReadLine())) {
                    if ($line -imatch $assembly_pattern) {
                        # verify the reference is not for .NET Framework
                        if ($Matches.ContainsKey("CLR") -and $Matches.CLR -ne "Core") {
                            continue
                        }
                        $assembly_path = $Matches.Name
                        if (-not ([System.IO.Path]::IsPathRooted($assembly_path))) {
                            $assembly_path = Join-Path -Path $lib_assembly_location -ChildPath $assembly_path
                        }
                        $assemblies.Add([Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile($assembly_path)) > $null
                    }
                    if ($line -imatch $no_warn_pattern) {
                        if ($Matches.ContainsKey("CLR") -and $Matches.CLR -ne "Core") {
                            continue
                        }
                        $ignore_warnings.Add($Matches.Name, [Microsoft.CodeAnalysis.ReportDiagnostic]::Suppress)
                    }
                }
            } finally {
                $sr.Close()
            }
            $syntax_trees.Add([Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($reference, $parse_options)) > $null
        }

        # Release seems to contain the correct line numbers compared to
        # debug,may need to keep a closer eye on this in the future
        $compiler_options = (New-Object -TypeName Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions -ArgumentList @(
            [Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary
        )).WithOptimizationLevel([Microsoft.CodeAnalysis.OptimizationLevel]::Release)

        # set warnings to error out if IgnoreWarnings is not set
        if (-not $IgnoreWarnings.IsPresent) {
            $compiler_options = $compiler_options.WithGeneralDiagnosticOption([Microsoft.CodeAnalysis.ReportDiagnostic]::Error)
            $compiler_options = $compiler_options.WithSpecificDiagnosticOptions($ignore_warnings)
        }

        # create compilation object
        $compilation = [Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create(
            [System.Guid]::NewGuid().ToString(),
            $syntax_trees,
            $assemblies,
            $compiler_options
        )

        # Load the compiled code and pdb info, we do this so we can
        # include line number in a stracktrace
        $code_ms = New-Object -TypeName System.IO.MemoryStream
        $pdb_ms = New-Object -TypeName System.IO.MemoryStream
        try {
            $emit_result = $compilation.Emit($code_ms, $pdb_ms)
            if (-not $emit_result.Success) {
                $errors = [System.Collections.ArrayList]@()

                foreach ($e in $emit_result.Diagnostics) {
                    # builds the error msg, based on logic in Add-Type
                    # https://github.com/PowerShell/PowerShell/blob/master/src/Microsoft.PowerShell.Commands.Utility/commands/utility/AddType.cs#L1239
                    if ($null -eq $e.Location.SourceTree) {
                        $errors.Add($e.ToString()) > $null
                        continue
                    }

                    $cancel_token = New-Object -TypeName System.Threading.CancellationToken -ArgumentList $false
                    $text_lines = $e.Location.SourceTree.GetText($cancel_token).Lines
                    $line_span = $e.Location.GetLineSpan()

                    $diagnostic_message = $e.ToString()
                    $error_line_string = $text_lines[$line_span.StartLinePosition.Line].ToString()
                    $error_position = $line_span.StartLinePosition.Character

                    $sb = New-Object -TypeName System.Text.StringBuilder -ArgumentList ($diagnostic_message.Length + $error_line_string.Length * 2 + 4)
                    $sb.AppendLine($diagnostic_message)
                    $sb.AppendLine($error_line_string)

                    for ($i = 0; $i -lt $error_line_string.Length; $i++) {
                        if ([System.Char]::IsWhiteSpace($error_line_string[$i])) {
                            continue
                        }
                        $sb.Append($error_line_string, 0, $i)
                        $sb.Append(' ', [Math]::Max(0, $error_position - $i))
                        $sb.Append("^")
                        break
                    }

                    $errors.Add($sb.ToString()) > $null
                }

                throw [InvalidOperationException]"Failed to compile C# code:`r`n$($errors -join "`r`n")"
            }

            $code_ms.Seek(0, [System.IO.SeekOrigin]::Begin) > $null
            $pdb_ms.Seek(0, [System.IO.SeekOrigin]::Begin) > $null
            $compiled_assembly = [System.Runtime.Loader.AssemblyLoadContext]::Default.LoadFromStream($code_ms, $pdb_ms)
        } finally {
            $code_ms.Close()
            $pdb_ms.Close()
        }
    } else {
        # compile the code using CodeDom on PSDesktop

        # configure compile options based on input
        if ($PSCmdlet.ParameterSetName -eq "Module") {
            $temp_path = $AnsibleModule.TmpDir
            $include_debug = $AnsibleModule.Verbosity -ge 3
        } else {
            $temp_path = $TempPath
            $include_debug = $IncludeDebugInfo.IsPresent
        }
        $compiler_options = [System.Collections.ArrayList]@("/optimize")
        if ($defined_symbols.Count -gt 0) {
            $compiler_options.Add("/define:" + ([String]::Join(";", $defined_symbols.ToArray()))) > $null
        }

        $compile_parameters = New-Object -TypeName System.CodeDom.Compiler.CompilerParameters
        $compile_parameters.GenerateExecutable = $false
        $compile_parameters.GenerateInMemory = $true
        $compile_parameters.TreatWarningsAsErrors = (-not $IgnoreWarnings.IsPresent)
        $compile_parameters.IncludeDebugInformation = $include_debug
        $compile_parameters.TempFiles = (New-Object -TypeName System.CodeDom.Compiler.TempFileCollection -ArgumentList $temp_path, $false)

        # Add-Type automatically references System.dll, System.Core.dll,
        # and System.Management.Automation.dll which we replicate here
        $assemblies = [System.Collections.Generic.HashSet`1[String]]@(
            "System.dll",
            "System.Core.dll",
            ([System.Reflection.Assembly]::GetAssembly([PSObject])).Location
        )

        # create a code snippet for each reference and check if we need
        # to reference any extra assemblies
        # //AssemblyReference -Name ... [-CLR Framework]
        $ignore_warnings = [System.Collections.ArrayList]@()
        $compile_units = [System.Collections.Generic.List`1[System.CodeDom.CodeSnippetCompileUnit]]@()
        foreach ($reference in $References) {
            $sr = New-Object -TypeName System.IO.StringReader -ArgumentList $reference
            try {
                while ($null -ne ($line = $sr.ReadLine())) {
                    if ($line -imatch $assembly_pattern) {
                        # verify the reference is not for .NET Core
                        if ($Matches.ContainsKey("CLR") -and $Matches.CLR -ne "Framework") {
                            continue
                        }
                        $assemblies.Add($Matches.Name) > $null
                    }
                    if ($line -imatch $no_warn_pattern) {
                        if ($Matches.ContainsKey("CLR") -and $Matches.CLR -ne "Framework") {
                            continue
                        }
                        $warning_id = $Matches.Name
                        # /nowarn should only contain the numeric part
                        if ($warning_id.StartsWith("CS")) {
                            $warning_id = $warning_id.Substring(2)
                        }
                        $ignore_warnings.Add($warning_id) > $null
                    }
                }
            } finally {
                $sr.Close()
            }
            $compile_units.Add((New-Object -TypeName System.CodeDom.CodeSnippetCompileUnit -ArgumentList $reference)) > $null
        }
        if ($ignore_warnings.Count -gt 0) {
            $compiler_options.Add("/nowarn:" + ([String]::Join(",", $ignore_warnings.ToArray()))) > $null
        }
        $compile_parameters.ReferencedAssemblies.AddRange($assemblies)
        $compile_parameters.CompilerOptions = [String]::Join(" ", $compiler_options.ToArray())

        # compile the code together and check for errors
        $provider = New-Object -TypeName Microsoft.CSharp.CSharpCodeProvider
        $compile = $provider.CompileAssemblyFromDom($compile_parameters, $compile_units.ToArray())
        if ($compile.Errors.HasErrors) {
            $msg = "Failed to compile C# code: "
            foreach ($e in $compile.Errors) {
                $msg += "`r`n" + $e.ToString()
            }
            throw [InvalidOperationException]$msg
        }
        $compiled_assembly = $compile.CompiledAssembly
    }

    # return the compiled assembly if PassThru is set.
    if ($PassThru) {
        return $compiled_assembly
    }
}

Export-ModuleMember -Function Add-CSharpType
