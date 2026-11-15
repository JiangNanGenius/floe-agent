// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floe contributors. See licenses/FLOE-STARTER-MIT.txt.
#if UNITY_EDITOR
using System;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEngine;

/// <summary>
/// Original Floe WebGL build bootstrap for the pinned Unity 2022.3 LTS editor.
/// The build is performed by the user's licensed Unity installation; this
/// package does not include or claim a produced WebGL artifact.
/// </summary>
public static class FloeWebBuild
{
    [MenuItem("Floe/Build WebGL")]
    public static void BuildFromMenu() => Build("Build/WebGL");

    public static void BuildFromCommandLine() => Build("Build/WebGL");

    private static void Build(string outputPath)
    {
        var options = new BuildPlayerOptions
        {
            scenes = new[] { "Assets/Scenes/Main.unity" },
            locationPathName = outputPath,
            target = BuildTarget.WebGL,
            options = BuildOptions.None,
        };
        var report = BuildPipeline.BuildPlayer(options);
        if (report.summary.result != BuildResult.Succeeded)
        {
            throw new Exception("Floe WebGL build failed: " + report.summary.result);
        }
        Debug.Log("Floe WebGL build succeeded: " + outputPath);
    }
}
#endif
