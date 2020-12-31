
Shader "Hidden/Clouds"
{

    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }
    SubShader
    {
        // No culling or depth
        Cull Off ZWrite Off ZTest Always

        Pass
        {
            CGPROGRAM

            #pragma vertex vert
            #pragma fragment frag
            #pragma target 5.0

            #include "UnityCG.cginc"
            float4 _MainTex_TexelSize;

            // vertex input: position, UV
            struct appdata {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f {
                float4 pos : SV_POSITION;
                float2 uv : TEXCOORD0;
                float3 viewVector : TEXCOORD1;
                float3 worldPos: TEXCOORD2;
            };

            // Vertex shader that procedurally outputs a full screen triangle
            v2f vert(appdata v)
            {

                #if UNITY_UV_STARTS_AT_TOP
                if (_MainTex_TexelSize.y < 0)
                    v.uv.y = 1-v.uv.y;
                #endif
                // Render settings
                float near = _ProjectionParams.y;
                float far = _ProjectionParams.z;
                float2 orthoSize = unity_OrthoParams.xy;

                v2f o;
                float3 pos = UnityObjectToClipPos(v.vertex);
                o.pos = float4(pos, 1);
                if (_ProjectionParams.x < 0)
                    pos.y = -pos.y;
                o.uv = v.uv;

                if (unity_OrthoParams.w)
                {
                    float3 viewVector = float4(0,0,1,0);
                    o.viewVector = mul(unity_CameraToWorld, float4(viewVector,0));

                    float4 worldPos = float4(float2(pos.x, pos.y) * orthoSize, near, 1);
                    o.worldPos = mul(unity_CameraToWorld, float4(worldPos));
                }
                else
                {
                    float3 viewVector = mul(unity_CameraInvProjection, float4(float2(pos.x, pos.y), 1, -1));
                    o.viewVector = mul(unity_CameraToWorld, float4(viewVector,0));

                    float3 worldPos = mul(unity_CameraInvProjection, float4(float2(pos.x, pos.y), near, -1));
                    o.worldPos = mul(unity_CameraToWorld, float4(worldPos,1));
                }

                return o;
            }

            // Textures
            // The main cloud texture
            Texture3D<float4> NoiseTex;
            // Whisps and detailing
            Texture3D<float4> DetailNoiseTex;
            // 1D texture to give the 'thunderhead' vibe
            Texture2D<float> AltitudeMap;

            SamplerState samplerNoiseTex;
            SamplerState samplerDetailNoiseTex;
            SamplerState samplerAltitudeMap;

            sampler2D _MainTex;
            sampler2D _CameraDepthTexture;


            // Noise combination parameters
            float densityMultiplier;
            float densityOffset;
            float scale;
            float detailNoiseScale;
            float detailNoiseWeight;
            // Weights to balance the 4 channels of the detail shader
            float3 detailWeights;
            float4 shapeNoiseWeights;

            // Parameters for the altitude taper
            float densityTaperUpStrength;
            float densityTaperUpStart;
            float densityTaperDownStrength;
            float densityTaperDownStart;

            // Private parameters to recreate altitudeMap's range
            float altitudeOffset;
            float altitudeMultiplier;

            // March settings
            float stepSizeRender;
            // Two opposite corners of the cloud container
            float3 boundsMin;
            float3 boundsMax;

            // Light settings
            float lightAbsorptionThroughCloud;
            float4 _LightColor0;

            // Animation settings
            float timeScale;
            float baseSpeed;
            float detailSpeed;

            // Returns (dstToBox, dstInsideBox). If ray misses box, dstInsideBox will be zero
            float2 rayBoxDst(float3 boundsMin, float3 boundsMax, float3 rayOrigin, float3 invRaydir) {
                // Adapted from: http://jcgt.org/published/0007/03/04/
                float3 t0 = (boundsMin - rayOrigin) * invRaydir;
                float3 t1 = (boundsMax - rayOrigin) * invRaydir;
                float3 tmin = min(t0, t1);
                float3 tmax = max(t0, t1);

                float dstA = max(max(tmin.x, tmin.y), tmin.z);
                float dstB = min(tmax.x, min(tmax.y, tmax.z));

                // CASE 1: ray intersects box from outside (0 <= dstA <= dstB)
                // dstA is dst to nearest intersection, dstB dst to far intersection

                // CASE 2: ray intersects box from inside (dstA < 0 < dstB)
                // dstA is the dst to intersection behind the ray, dstB is dst to forward intersection

                // CASE 3: ray misses box (dstA > dstB)

                float dstToBox = max(0, dstA);
                float dstInsideBox = max(0, dstB - dstToBox);
                return float2(dstToBox, dstInsideBox);
            }

            float beer(float d) {
                float beer = exp(-d);
                return beer;
            }

            float altitudeDensity(float heightPercent)
            {
                // If we want altidtude uncomment this
                return sqrt(AltitudeMap.SampleLevel(samplerAltitudeMap, heightPercent, 0)) * altitudeMultiplier + altitudeOffset;
            }

            float sampleDensity(float3 rayPos) {
                // Constants:
                const int mipLevel = 2;
                const float baseScale = 1/1000.0;

                // Calculate texture sample positions
                float time = _Time.x * timeScale;
                float3 size = boundsMax - boundsMin;
                float3 uvw = (float3(3200, 1400, 3200) / 2 + rayPos) * baseScale * scale + float3(time, time * 0.1, time * 0.2) * baseSpeed;

                // Sets a gradient tapering off at the top and bottom, avoiding ugly flat spots (which tend to look buggy)
                float heightPercent = (rayPos.y - boundsMin.y) / size.y;

                float heightDensityOffset = min(
                    min(
                        (heightPercent - densityTaperDownStart) * densityTaperDownStrength,
                        (densityTaperUpStart - heightPercent) * densityTaperUpStrength
                    ), 0);

                float altDensity = altitudeDensity(heightPercent) / 2 + heightDensityOffset;

                // Calculate meta shape density
                // Duplicated code to create a meta layer of clouds
                // TODO: Fully seperate from normal noise settings
                float3 shapeSamplePosMeta = uvw;
                shapeSamplePosMeta /= 10;

                float4 shapeNoiseMeta = NoiseTex.SampleLevel(samplerNoiseTex, shapeSamplePosMeta , mipLevel);
                float4 normalizedShapeWeightsMeta = shapeNoiseWeights / dot(shapeNoiseWeights, 1);
                float shapeFBMMeta = dot(shapeNoiseMeta, normalizedShapeWeightsMeta);
                float baseShapeDensityMeta = (shapeFBMMeta + densityOffset * .1 - 0.1) * 15;

                // Add altitude density
                baseShapeDensityMeta += altDensity;

                // Early returning if further calculations is unlikely to affect results
                if (baseShapeDensityMeta < -1 - densityOffset / 10)
                    return baseShapeDensityMeta;

                // Calculate base shape density
                float3 shapeSamplePos = uvw + float3(time,time*0.1,time*0.2) * baseSpeed;
                float4 shapeNoise = NoiseTex.SampleLevel(samplerNoiseTex, shapeSamplePos, mipLevel);
                float4 normalizedShapeWeights = shapeNoiseWeights / dot(shapeNoiseWeights, 1);
                float shapeFBM = dot(shapeNoise, normalizedShapeWeights);
                float baseShapeDensity = shapeFBM + densityOffset * .1;

                baseShapeDensity += baseShapeDensityMeta;

                // Sample detail noise
                float3 detailSamplePos = uvw*detailNoiseScale + float3(time*.4,-time,time*0.1)*detailSpeed;
                float4 detailNoise = DetailNoiseTex.SampleLevel(samplerDetailNoiseTex, detailSamplePos, mipLevel);
                float3 normalizedDetailWeights = detailWeights / dot(detailWeights, 1);
                float detailFBM = dot(detailNoise, normalizedDetailWeights);

                // Subtract detail noise from base shape (weighted by inverse density so that edges get eroded more than centre)
                float oneMinusShape = 1 - shapeFBM;
                float detailErodeWeight = oneMinusShape * oneMinusShape * oneMinusShape;
                float cloudDensity = baseShapeDensity - (1-detailFBM) * detailErodeWeight * detailNoiseWeight; 
                cloudDensity *= densityMultiplier / 2;

                return lerp(cloudDensity, baseShapeDensity, 0);
            }


            float getDepth(float2 uv)
            {
                float nonlin_depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, UnityStereoTransformScreenSpaceTex(uv));

                // TODO: figure out why negative near planes break the depths
                if (unity_OrthoParams.w)
                {
                    #ifdef UNITY_REVERSED_Z
                    return lerp(_ProjectionParams.z, _ProjectionParams.y, nonlin_depth) - _ProjectionParams.y;
                    #else
                    return lerp(_ProjectionParams.y, _ProjectionParams.z, nonlin_depth) - _ProjectionParams.y;
                    #endif
                }
                else
                    return LinearEyeDepth(nonlin_depth);
            }

            fixed3 getCloudColor(float currentDepth, float lightEnergy)
            {
                return _LightColor0 * lightEnergy;
            }

            float4 rayMarch(float3 rayPos, float3 rayDir, float depth, float2 uv);

            float4 frag (v2f i) : SV_Target
            {
                // Create ray
                float3 rayPos = i.worldPos;
                float3 rayDir = i.viewVector;

                // Get the depth value
                float depth = getDepth(i.uv);

                return rayMarch(rayPos, rayDir, depth, i.uv);
            }

            float4 rayMarch(float3 rayPos, float3 rayDir, float depth, float2 uv) {

                // Normalize ray because of perspective interpolation
                float distancePerspectiveModifier = length(rayDir);
                rayDir = rayDir / distancePerspectiveModifier;

                // Normalize depth the same way
                depth *= distancePerspectiveModifier;

                float2 rayToContainerInfo = rayBoxDst(boundsMin, boundsMax, rayPos, 1/rayDir);
                float dstToBox = rayToContainerInfo.x;
                float dstInsideBox = rayToContainerInfo.y;

                // point of intersection with the cloud container
                float3 entryPoint = rayPos + rayDir * dstToBox;

                float dstTravelled = 0;
                float dstLimit = min(depth-dstToBox, dstInsideBox);

                float stepSize = stepSizeRender;

                // March through volume:
                float transmittance = 1;
                float lightEnergy = 0;

                while (dstTravelled < dstLimit) {

                    rayPos = entryPoint + rayDir * dstTravelled;
                    float density = max(sampleDensity(rayPos), 0);

                    transmittance *= beer(density * stepSize * lightAbsorptionThroughCloud);
                    lightEnergy += density * stepSize * transmittance * 0.5;
                    transmittance /= sqrt(beer(density * stepSize * lightAbsorptionThroughCloud));

                    dstTravelled += stepSize;
                }

                float currentDepth;
                if (dstInsideBox > 0)
                    currentDepth = dstToBox + dstTravelled;
                else
                    currentDepth = depth;

                // Skybox and plane
                fixed3 backgroundCol = tex2D(_MainTex, uv);

                // Decrease light energy contrast
                lightEnergy *= 0.5;

                // Add clouds
                // When absorption (1 - transmittance) is low, less light energy has accumulated
                // This value accounts for that
                float lowAbsorptionLightBalance = transmittance == 1 ? 1 : 1 / (1-transmittance);
                // Get the cloud color depending on distance, and adjusted light energy
                fixed3 col = getCloudColor(currentDepth, lightEnergy * lowAbsorptionLightBalance);

                // Add background or plane/objects
                col = lerp(col, backgroundCol, transmittance);

                return float4(col,0);
            }

            ENDCG
        }
    }
}
