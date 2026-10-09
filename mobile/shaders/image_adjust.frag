#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

// Tone and colour adjustments of the built-in editor, applied to an image
// that already has its final crop, rotation and size. Every adjustment ranges
// from -1 to 1 with 0 leaving the image unchanged.

uniform vec2 uSize;
// keep in the order of ToneAdjustment (image_adjustments.model.dart)
uniform float uBrightness;
uniform float uContrast;
uniform float uWhitePoint;
uniform float uHighlights;
uniform float uShadows;
uniform float uBlackPoint;
uniform float uVignette;
uniform float uSaturation;
uniform float uVibrance;
uniform float uWarmth;
uniform float uTint;
uniform sampler2D uImage;

out vec4 fragColor;

const vec3 kLuma = vec3(0.2126, 0.7152, 0.0722);

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  vec4 texel = texture(uImage, uv);
  vec3 c = texel.a > 0.0 ? texel.rgb / texel.a : vec3(0.0);

  // brightness as exposure: up to one stop darker or brighter
  c *= exp2(uBrightness);

  // white point brightens towards white, black point deepens towards black
  float black = 0.15 * uBlackPoint;
  float white = 1.0 - 0.25 * uWhitePoint;
  c = (c - black) / (white - black);

  // contrast around mid grey
  float contrast = uContrast > 0.0 ? 1.0 + uContrast : 1.0 + 0.7 * uContrast;
  c = (c - 0.5) * contrast + 0.5;

  // shadows and highlights brighten or darken only the dark or bright tones,
  // as a gain so pure black and the hue are kept
  float luma = clamp(dot(clamp(c, 0.0, 1.0), kLuma), 0.0, 1.0);
  float shadowWeight = 1.0 - smoothstep(0.0, 0.6, luma);
  float highlightWeight = smoothstep(0.4, 1.0, luma);
  c *= exp2(uShadows * shadowWeight + 0.6 * uHighlights * highlightWeight);

  // saturation for all colours, vibrance mostly for the muted ones
  luma = dot(c, kLuma);
  c = mix(vec3(luma), c, 1.0 + uSaturation);
  vec3 clamped = clamp(c, 0.0, 1.0);
  float chroma = max(clamped.r, max(clamped.g, clamped.b)) - min(clamped.r, min(clamped.g, clamped.b));
  luma = dot(c, kLuma);
  c = mix(vec3(luma), c, 1.0 + uVibrance * (1.0 - chroma));

  // warmth balances red against blue, tint magenta against green
  c *= vec3(1.0 + 0.2 * uWarmth, 1.0 + 0.03 * uWarmth, 1.0 - 0.2 * uWarmth);
  c *= vec3(1.0 + 0.05 * uTint, 1.0 - 0.15 * uTint, 1.0 + 0.05 * uTint);

  // vignette darkens (negative) or lightens (positive) towards the corners
  float distance = length((uv - 0.5) * 2.0) / sqrt(2.0);
  c *= 1.0 + 0.8 * uVignette * smoothstep(0.35, 1.0, distance);

  fragColor = vec4(clamp(c, 0.0, 1.0) * texel.a, texel.a);
}
