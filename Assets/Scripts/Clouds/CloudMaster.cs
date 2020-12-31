using System.Collections;
using System.Collections.Generic;
using UnityEngine;

[ExecuteInEditMode, ImageEffectAllowedInSceneView]
public class CloudMaster : MonoBehaviour {
    const string headerDecoration = " --- ";
    [Header (headerDecoration + "Main" + headerDecoration)]
    public Shader shader;
    public Transform container;

    [Header (headerDecoration + "March settings" + headerDecoration)]
    public float stepSizeRender = 8;

    [Header (headerDecoration + "Base Shape" + headerDecoration)]
    public float cloudScale = 1;
    public float densityMultiplier = 1;
    public float densityOffset;
    public Vector4 shapeNoiseWeights;

    [Header (headerDecoration + "Limit Taper Settings" + headerDecoration)]
    [Range (0, 100)]
    public float densityTaperUpStrength = 30;
    [Range (0, 1)]
    public float densityTaperUpStart = 0.8f;
    [Range (0, 100)]
    public float densityTaperDownStrength = 30;
    [Range (0, 1)]
    public float densityTaperDownStart = 0.2f;

    [Header (headerDecoration + "Detail" + headerDecoration)]
    public float detailNoiseScale = 10;
    public float detailNoiseWeight = .1f;
    public Vector3 detailNoiseWeights;

    [Header (headerDecoration + "Lighting" + headerDecoration)]
    public float lightAbsorptionThroughCloud = 1;

    [Header (headerDecoration + "Animation" + headerDecoration)]
    public float timeScale = 1;
    public float baseSpeed = 1;
    public float detailSpeed = 2;

    // Internal
    [HideInInspector]
    public Material material;

    bool isMaterialDirty = true;
    private Vector3 lastContainerPosition;

    // The texture generators for the shader
    private NoiseGenerator noiseGen;
    private AltitudeMap altitudeMapGen;

    void UpdateMaps()
    {
        altitudeMapGen = FindObjectOfType<AltitudeMap> ();
        noiseGen = FindObjectOfType<NoiseGenerator> ();
        altitudeMapGen.UpdateMap ();
    }

    void Awake () {
        if (Application.isPlaying)
            UpdateMaps();
        Application.targetFrameRate = 60;
    }


    //Create a new texture
    Texture2D texture;
    Color sampledOutputPixel;

    public float GetLight() {
        if (sampledOutputPixel.b != 0f || sampledOutputPixel.a != 1f)
            return -1f;

        return sampledOutputPixel.g;
    }
    public float GetDensity() {
        if (sampledOutputPixel.b != 0f || sampledOutputPixel.a != 1f)
            return -1f;

        return sampledOutputPixel.r;
    }

    [ImageEffectOpaque]
    private void OnRenderImage (RenderTexture src, RenderTexture dest) {

        if (!texture)
            texture = new Texture2D(1, 1, TextureFormat.RGB24, false);

        if (isMaterialDirty || material == null || Application.isPlaying == false)
        {
            isMaterialDirty = false;

            // Validate inputs
            if (material == null || material.shader != shader) {
                material = new Material (shader);
            }

            SetParams();
        }

        material.SetVector ("boundsMin", container.position - container.localScale / 2);
        material.SetVector ("boundsMax", container.position + container.localScale / 2);
        lastContainerPosition = container.position;

        // Blit does the following:
        // - sets _MainTex property on material to the source texture
        // - sets the render target to the destination texture
        // - draws a full-screen quad
        // This copies the src texture to the dest texture, with whatever modifications the shader makes
        Graphics.Blit (src, dest, material);

        //Read the pixel in the Rect starting at 0,0 
        texture.ReadPixels(new Rect(0, 0, 1, 1), 0, 0, false);
        texture.Apply();
        this.sampledOutputPixel = texture.GetPixel(0, 0);
    }

    void SetParams ()
    {
        stepSizeRender = Mathf.Max(1, stepSizeRender);

        // Noise
        var noise = FindObjectOfType<NoiseGenerator> ();
        noise.UpdateNoise ();

        material.SetTexture ("NoiseTex", noise.shapeTexture);
        material.SetTexture ("DetailNoiseTex", noise.detailTexture);

        UpdateMaps();
        material.SetTexture ("AltitudeMap", altitudeMapGen.altitudeMap);
        material.SetFloat("altitudeOffset", altitudeMapGen.altitudeOffset);
        material.SetFloat("altitudeMultiplier", altitudeMapGen.altitudeMultiplier);

        // Marching settings
        Vector3 size = container.localScale;
        int width = Mathf.CeilToInt (size.x);
        int height = Mathf.CeilToInt (size.y);
        int depth = Mathf.CeilToInt (size.z);

        material.SetFloat ("scale", cloudScale);
        material.SetFloat ("densityMultiplier", densityMultiplier);
        material.SetFloat ("densityOffset", densityOffset);
        material.SetFloat ("lightAbsorptionThroughCloud", lightAbsorptionThroughCloud);

        material.SetFloat ("detailNoiseScale", detailNoiseScale);
        material.SetFloat ("detailNoiseWeight", detailNoiseWeight);
        material.SetVector ("detailWeights", detailNoiseWeights);
        material.SetVector ("shapeNoiseWeights", shapeNoiseWeights);

        material.SetFloat("densityTaperUpStrength", densityTaperUpStrength);
        material.SetFloat("densityTaperUpStart", densityTaperUpStart);
        material.SetFloat("densityTaperDownStrength", densityTaperDownStrength);
        material.SetFloat("densityTaperDownStart", densityTaperDownStart);

        material.SetVector ("boundsMin", container.position - container.localScale / 2);
        material.SetVector ("boundsMax", container.position + container.localScale / 2);

        material.SetFloat("stepSizeRender", stepSizeRender);

        material.SetVector ("mapSize", new Vector4 (width, height, depth, 0));

        material.SetFloat ("timeScale", (Application.isPlaying) ? timeScale : 0);
        material.SetFloat ("baseSpeed", baseSpeed);
        material.SetFloat ("detailSpeed", detailSpeed);
    }

    void OnValidate() {
        isMaterialDirty = true;
    }
}