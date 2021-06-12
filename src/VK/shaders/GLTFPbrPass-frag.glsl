#version 450

// Portions Copyright 2019 Advanced Micro Devices, Inc.All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
 
// This shader code was ported from https://github.com/KhronosGroup/glTF-WebGL-PBR
// All credits should go to his original author.

//
// This fragment shader defines a reference implementation for Physically Based Shading of
// a microfacet surface material defined by a glTF model.
//
// References:
// [1] Real Shading in Unreal Engine 4
//     http://blog.selfshadow.com/publications/s2013-shading-course/karis/s2013_pbs_epic_notes_v2.pdf
// [2] Physically Based Shading at Disney
//     http://blog.selfshadow.com/publications/s2012-shading-course/burley/s2012_pbs_disney_brdf_notes_v3.pdf
// [3] README.md - Environment Maps
//     https://github.com/KhronosGroup/glTF-WebGL-PBR/#environment-maps
// [4] "An Inexpensive BRDF Model for Physically based Rendering" by Christophe Schlick
//     https://www.cs.virginia.edu/~jdl/bib/appearance/analytic%20models/schlick94b.pdf

//#extension GL_OES_standard_derivatives : enable

#extension GL_EXT_shader_texture_lod: enable
#extension GL_ARB_separate_shader_objects : enable
#extension GL_ARB_shading_language_420pack : enable
// this makes the structures declared with a scalar layout match the c structures
#extension GL_EXT_scalar_block_layout : enable

precision highp float;

#define USE_PUNCTUAL

//--------------------------------------------------------------------------------------
//  PS Inputs
//--------------------------------------------------------------------------------------

#include "GLTF_VS2PS_IO.glsl"
layout (location = 0) in VS2PS Input;

//--------------------------------------------------------------------------------------
// PS Outputs
//--------------------------------------------------------------------------------------

#ifdef HAS_MOTION_VECTORS_RT
layout(location = HAS_MOTION_VECTORS_RT) out vec2 Output_motionVect;
#endif

#ifdef HAS_FORWARD_RT
    layout (location = HAS_FORWARD_RT) out vec4 Output_finalColor;
#endif

#ifdef HAS_EMISSIVE_FLUX_RT
    layout (location = HAS_EMISSIVE_FLUX_RT) out vec4 Output_emissiveColor;
#endif

#ifdef HAS_SPECULAR_ROUGHNESS_RT
    layout (location = HAS_SPECULAR_ROUGHNESS_RT) out vec4 Output_specularRoughness;
#endif

#ifdef HAS_DIFFUSE_RT
    layout (location = HAS_DIFFUSE_RT) out vec4 Output_diffuseColor;
#endif

#ifdef HAS_NORMALS_RT
    layout (location = HAS_NORMALS_RT) out vec4 Output_normal;
#endif

#ifdef HAS_WORLD_COORD_RT
    layout (location = HAS_WORLD_COORD_RT) out vec4 Output_worldCoord;
#endif

//--------------------------------------------------------------------------------------
//
// Constant Buffers 
//
//--------------------------------------------------------------------------------------

layout (push_constant) uniform pushConstants
{
    layout (offset = 0) int rsmLightIndex;
};

//--------------------------------------------------------------------------------------
// Per Frame structure, must match the one in GlTFCommon.h
//--------------------------------------------------------------------------------------

#include "perFrameStruct.h"

layout (scalar, set=0, binding = 0) uniform perFrame 
{
	PerFrame myPerFrame;
};

//--------------------------------------------------------------------------------------
// PerFrame structure, must match the one in GltfPbrPass.h
//--------------------------------------------------------------------------------------

#include "PixelParams.glsl"

layout (scalar, set=0, binding = 1) uniform perObject 
{
    mat4 myPerObject_u_mCurrWorld;
    mat4 myPerObject_u_mPrevWorld;

	PBRFactors u_pbrParams;
};


//--------------------------------------------------------------------------------------
// mainPS
//--------------------------------------------------------------------------------------

#include "functions.glsl"
#include "shadowFiltering.h"
#include "GLTFPBRLighting.h"

void main()
{
    discardPixelIfAlphaCutOff(Input);

    float alpha;
    float perceptualRoughness;
    vec3 diffuseColor;
    vec3 specularColor;
	getPBRParams(Input, u_pbrParams, diffuseColor, specularColor, perceptualRoughness, alpha);

#ifdef HAS_MOTION_VECTORS_RT 
    Output_motionVect = Input.CurrPosition.xy / Input.CurrPosition.w -
                        Input.PrevPosition.xy / Input.PrevPosition.w;
#endif

#ifdef HAS_WORLD_COORD_RT
    Output_worldCoord = vec4(Input.WorldPos, 1);
#endif

#ifdef HAS_NORMALS_RT
    vec3 normal = getPixelNormal(Input);

#if (DEF_doubleSided == 1)
    vec3 cameraPos;
    if (rsmLightIndex < 0)
        cameraPos = myPerFrame.u_CameraPos.xyz;
    else
        cameraPos = myPerFrame.u_lights[rsmLightIndex].position;

    if (dot(normal, normalize(cameraPos - Input.WorldPos)) < 0)
    {
        normal = -normal;
    }
#endif

    // PBR terms for additional (optional) shading
    float ao = 1.0;
#ifdef ID_occlusionTexture
    ao = texture(u_OcclusionSampler, getOcclusionUV(Input)).r;
#endif

    Output_normal = vec4((normal + 1) / 2, ao);
#endif

#ifdef HAS_SPECULAR_ROUGHNESS_RT
    Output_specularRoughness = vec4(specularColor, perceptualRoughness);
#endif

#ifdef HAS_DIFFUSE_RT
    Output_diffuseColor = vec4(diffuseColor, 1.0);
#endif

#ifdef HAS_EMISSIVE_FLUX_RT
    // for screen G-Buffer => output 'emissive' 
    if (rsmLightIndex < 0)
    {
        vec3 emissive;
#ifdef ID_emissiveTexture
        emissive = texture(u_EmissiveSampler, getEmissiveUV(Input)).rgb * u_pbrParams.myPerObject_u_EmissiveFactor.rgb * myPerFrame.u_EmissiveFactor;
#else
        emissive = u_pbrParams.myPerObject_u_EmissiveFactor.rgb * myPerFrame.u_EmissiveFactor;
#endif
        Output_emissiveColor = vec4(emissive, alpha);
    }
    // for light RSM => output 'flux' instead
    else 
    {
        vec3 flux = getBaseColor(Input, u_pbrParams).rgb;

        //  now RSM supports only Directional Light and Spotlight
        int lightType = myPerFrame.u_lights[rsmLightIndex].type;
        if (lightType == LightType_Directional)
        {
            flux *= getDirectionalLightFlux(myPerFrame.u_lights[rsmLightIndex]);
        }
        else if (lightType == LightType_Spot)
        {
            vec3 pointToLight = myPerFrame.u_lights[rsmLightIndex].position - Input.WorldPos;
            flux *= getSpotLightFlux(myPerFrame.u_lights[rsmLightIndex], pointToLight);
        }

        Output_emissiveColor = vec4(flux, alpha);
    }
#endif

#ifdef HAS_FORWARD_RT
	Output_finalColor = vec4(doPbrLighting(Input, myPerFrame, diffuseColor, specularColor, perceptualRoughness), alpha);
#endif
}
