// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floe contributors. See licenses/FLOE-STARTER-MIT.txt.
using System;
using UnityEngine;

/// <summary>
/// Original, self-contained Floe starter for Unity. It builds the whole scene at
/// runtime with standard UnityEngine APIs and draws its UI with IMGUI, so the
/// project needs no imported art, prefabs or third-party packages.
/// </summary>
public sealed class FloeStarter : MonoBehaviour
{
    private const float Width = 816f;
    private const float Height = 624f;
    private const float Tile = 48f;
    private const string SaveKey = "floe.glimmerfen.save.v1";

    [Serializable]
    private sealed class SaveData
    {
        public int version;
        public int x;
        public int y;
        public int steps;
        public int score;
    }

    private int playerX = 2;
    private int playerY = 2;
    private int steps;
    private int score;
    private bool menu;
    private int menuIndex;
    private string message = string.Empty;
    private float messageUntil;
    private Texture2D white;
    private Texture2D player;
    private Texture2D coin;

    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
    private static void Bootstrap()
    {
        if (FindObjectOfType<FloeStarter>() != null) return;
        var root = new GameObject("Floe Starter");
        root.AddComponent<FloeStarter>();
    }

    private void Awake()
    {
        DontDestroyOnLoad(gameObject);
        if (Camera.main == null)
        {
            var cameraObject = new GameObject("Floe Camera");
            var camera = cameraObject.AddComponent<Camera>();
            camera.clearFlags = CameraClearFlags.SolidColor;
            camera.backgroundColor = new Color(0.055f, 0.11f, 0.094f, 1f);
            camera.orthographic = true;
            camera.orthographicSize = Height / 2f;
            cameraObject.tag = "MainCamera";
        }
        white = MakeTexture(1, 1, Color.white);
        player = MakeCircleTexture(32, new Color(0.56f, 0.84f, 1f, 1f));
        coin = MakeCircleTexture(20, new Color(1f, 0.81f, 0.33f, 1f));
    }

    private static Texture2D MakeTexture(int width, int height, Color color)
    {
        var texture = new Texture2D(width, height, TextureFormat.RGBA32, false);
        var pixels = new Color[width * height];
        for (var i = 0; i < pixels.Length; i++) pixels[i] = color;
        texture.SetPixels(pixels);
        texture.Apply();
        return texture;
    }

    private static Texture2D MakeCircleTexture(int size, Color color)
    {
        var texture = new Texture2D(size, size, TextureFormat.RGBA32, false);
        var pixels = new Color[size * size];
        var center = (size - 1) / 2f;
        for (var y = 0; y < size; y++)
        {
            for (var x = 0; x < size; x++)
            {
                var dx = x - center;
                var dy = y - center;
                pixels[y * size + x] = dx * dx + dy * dy <= (size * 0.42f) * (size * 0.42f)
                    ? color : Color.clear;
            }
        }
        texture.SetPixels(pixels);
        texture.Apply();
        return texture;
    }

    private void Update()
    {
        if (messageUntil > 0f && Time.time > messageUntil) message = string.Empty;
        if (menu)
        {
            if (Input.GetKeyDown(KeyCode.UpArrow)) menuIndex = (menuIndex + 2) % 3;
            if (Input.GetKeyDown(KeyCode.DownArrow)) menuIndex = (menuIndex + 1) % 3;
            if (ConfirmPressed())
            {
                if (menuIndex == 1) SaveGame();
                if (menuIndex == 2) LoadGame();
                menu = false;
            }
            if (CancelPressed()) menu = false;
            return;
        }
        if (CancelPressed())
        {
            menu = true;
            menuIndex = 0;
            return;
        }
        if (ConfirmPressed())
        {
            var near = (playerX == 4 && playerY == 3) || (playerX == 8 && playerY == 6);
            Say(near ? "The ferry keeper nods. One rope coil, one crossing."
                     : "The fen is quiet. The ferry waits to the east.");
            if (playerX == 8 && playerY == 6 && score == 0)
            {
                score = 1;
                Say("You pocket a coil of rope from the notice stone.");
            }
            return;
        }
        if (Input.GetKey(KeyCode.LeftArrow)) Move(-1, 0);
        else if (Input.GetKey(KeyCode.RightArrow)) Move(1, 0);
        else if (Input.GetKey(KeyCode.UpArrow)) Move(0, -1);
        else if (Input.GetKey(KeyCode.DownArrow)) Move(0, 1);
        if (Input.GetKeyDown(KeyCode.F5)) SaveGame();
        if (Input.GetKeyDown(KeyCode.F9)) LoadGame();
        if (Input.GetKeyDown(KeyCode.Q)) menuIndex = (menuIndex + 2) % 3;
        if (Input.GetKeyDown(KeyCode.W)) menuIndex = (menuIndex + 1) % 3;
    }

    private static bool ConfirmPressed()
    {
        return Input.GetKeyDown(KeyCode.Z) || Input.GetKeyDown(KeyCode.Return) ||
               Input.GetKeyDown(KeyCode.Space);
    }

    private static bool CancelPressed()
    {
        return Input.GetKeyDown(KeyCode.X) || Input.GetKeyDown(KeyCode.Escape);
    }

    private void Move(int dx, int dy)
    {
        var nx = Mathf.Clamp(playerX + dx, 0, 11);
        var ny = Mathf.Clamp(playerY + dy, 0, 9);
        if (nx == playerX && ny == playerY) return;
        playerX = nx;
        playerY = ny;
        steps++;
        if (playerX == 8 && playerY == 6 && score == 0)
        {
            score = 1;
            Say("You pocket a coil of rope from the notice stone.");
        }
    }

    private void Say(string text)
    {
        message = text;
        messageUntil = Time.time + 4f;
    }

    private void SaveGame()
    {
        var data = new SaveData { version = 1, x = playerX, y = playerY, steps = steps, score = score };
        PlayerPrefs.SetString(SaveKey, JsonUtility.ToJson(data));
        PlayerPrefs.Save();
        Say("Saved to PlayerPrefs.");
    }

    private void LoadGame()
    {
        var raw = PlayerPrefs.GetString(SaveKey, string.Empty);
        if (string.IsNullOrEmpty(raw))
        {
            Say("No save yet.");
            return;
        }
        try
        {
            var data = JsonUtility.FromJson<SaveData>(raw);
            if (data == null || data.version != 1) { Say("That save is not compatible."); return; }
            playerX = Mathf.Clamp(data.x, 0, 11);
            playerY = Mathf.Clamp(data.y, 0, 9);
            steps = Mathf.Max(0, data.steps);
            score = Mathf.Clamp(data.score, 0, 1);
            Say("Loaded from PlayerPrefs.");
        }
        catch (Exception)
        {
            Say("The save could not be read.");
        }
    }

    private void OnGUI()
    {
        var scale = Mathf.Min(Screen.width / Width, Screen.height / Height);
        var offsetX = (Screen.width - Width * scale) / 2f;
        var offsetY = (Screen.height - Height * scale) / 2f;
        GUI.matrix = Matrix4x4.TRS(new Vector3(offsetX, offsetY, 0f),
            Quaternion.identity, new Vector3(scale, scale, 1f));
        GUI.color = new Color(0.075f, 0.137f, 0.118f, 1f);
        GUI.DrawTexture(new Rect(0, 0, Width, Height), white);
        for (var y = 0; y < 10; y++)
        {
            for (var x = 0; x < 12; x++)
            {
                var edge = x == 0 || y == 0 || x == 11 || y == 9;
                GUI.color = edge ? new Color(0.15f, 0.24f, 0.20f, 1f)
                                 : new Color(0.12f + (x + y) % 3 * 0.015f,
                                             0.23f + (x * 3 + y) % 4 * 0.012f, 0.185f, 1f);
                GUI.DrawTexture(new Rect(x * Tile + 2, y * Tile + 2, Tile - 4, Tile - 4), white);
            }
        }
        if (score == 0)
        {
            GUI.color = Color.white;
            GUI.DrawTexture(new Rect(8 * Tile + 14, 6 * Tile + 14, 20, 20), coin);
        }
        GUI.color = Color.white;
        GUI.DrawTexture(new Rect(playerX * Tile + 8, playerY * Tile + 8, 32, 32), player);
        GUI.color = new Color(0.93f, 0.94f, 0.85f, 1f);
        GUI.Label(new Rect(16, 12, 600, 30), $"Glimmerfen   steps {steps}   rope {score}/1");
        GUI.Label(new Rect(600, 12, 200, 30), "C talk   B menu");
        if (!string.IsNullOrEmpty(message))
        {
            GUI.color = new Color(0.07f, 0.12f, 0.10f, 0.92f);
            GUI.DrawTexture(new Rect(0, Height - 92, Width, 92), white);
            GUI.color = new Color(0.96f, 0.94f, 0.82f, 1f);
            GUI.Label(new Rect(18, Height - 72, Width - 36, 60), message);
        }
        if (menu)
        {
            GUI.color = new Color(0.08f, 0.14f, 0.12f, 0.96f);
            GUI.DrawTexture(new Rect(250, 170, 260, 150), white);
            GUI.color = new Color(1f, 0.88f, 0.55f, 1f);
            var items = new[] { "Resume", "Save", "Load" };
            for (var i = 0; i < items.Length; i++)
            {
                GUI.Label(new Rect(275, 185 + i * 36, 220, 30),
                    (i == menuIndex ? "▶ " : "  ") + items[i]);
            }
        }
    }
}
