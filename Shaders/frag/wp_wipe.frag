// ===== wp_wipe.frag =====
#version 450

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(binding = 1) uniform sampler2D source1;  // Current wallpaper
layout(binding = 2) uniform sampler2D source2;  // Next wallpaper

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float progress;      // Transition progress (0.0 to 1.0)
    float direction;     // 0=left, 1=right, 2=up, 3=down
    float smoothness;    // Edge smoothness (0.0 to 1.0, 0=sharp, 1=very smooth)

    // Fill mode parameters
    float fillMode;      // 0=center, 1=crop, 2=fit, 3=stretch, 4=repeat, 5=blur
    float imageWidth1;   // Width of source1 image
    float imageHeight1;  // Height of source1 image
    float imageWidth2;   // Width of source2 image
    float imageHeight2;  // Height of source2 image
    float screenWidth;   // Screen width
    float screenHeight;  // Screen height
    vec4 fillColor;      // Fill color for empty areas (default: black)

    // Solid color mode
    float isSolid1;      // 1.0 if source1 is solid color, 0.0 otherwise
    float isSolid2;      // 1.0 if source2 is solid color, 0.0 otherwise
    vec4 solidColor1;    // Solid color for source1
    vec4 solidColor2;    // Solid color for source2
} ubuf;

// Calculate UV coordinates based on fill mode
vec2 calculateUV(vec2 uv, float imgWidth, float imgHeight) {
    float imageAspect = imgWidth / imgHeight;
    float screenAspect = ubuf.screenWidth / ubuf.screenHeight;
    vec2 transformedUV = uv;

    if (ubuf.fillMode < 0.5) {
        // Mode 0: no (center) - No resize, center image at original size
        // Convert UV to pixel coordinates, offset, then back to UV in image space
        vec2 screenPixel = uv * vec2(ubuf.screenWidth, ubuf.screenHeight);
        vec2 imageOffset = (vec2(ubuf.screenWidth, ubuf.screenHeight) - vec2(imgWidth, imgHeight)) * 0.5;
        vec2 imagePixel = screenPixel - imageOffset;
        transformedUV = imagePixel / vec2(imgWidth, imgHeight);
    }
    else if (ubuf.fillMode < 1.5) {
        // Mode 1: crop (fill/cover) - Fill screen, crop excess (default)
        float scale = max(ubuf.screenWidth / imgWidth, ubuf.screenHeight / imgHeight);
        vec2 scaledImageSize = vec2(imgWidth, imgHeight) * scale;
        vec2 offset = (scaledImageSize - vec2(ubuf.screenWidth, ubuf.screenHeight)) / scaledImageSize;
        transformedUV = uv * (vec2(1.0) - offset) + offset * 0.5;
    }
    else if (ubuf.fillMode < 2.5) {
        // Mode 2: fit (contain) - Fit inside screen, maintain aspect ratio
        float scale = min(ubuf.screenWidth / imgWidth, ubuf.screenHeight / imgHeight);
        vec2 scaledImageSize = vec2(imgWidth, imgHeight) * scale;
        vec2 offset = (vec2(ubuf.screenWidth, ubuf.screenHeight) - scaledImageSize) * 0.5;

        // Convert screen UV to pixel coordinates
        vec2 screenPixel = uv * vec2(ubuf.screenWidth, ubuf.screenHeight);
        // Adjust for offset and scale
        vec2 imagePixel = (screenPixel - offset) / scale;
        // Convert back to UV coordinates in image space
        transformedUV = imagePixel / vec2(imgWidth, imgHeight);
    }
    else if (ubuf.fillMode < 3.5) {
        // Mode 3: stretch - Use original UV (stretches to fit)
        // No transformation needed for stretch mode
    }
    else {
        // Mode 4: repeat (tile) - Tile image at original size
        vec2 screenPixel = uv * vec2(ubuf.screenWidth, ubuf.screenHeight);
        transformedUV = screenPixel / vec2(imgWidth, imgHeight);
    }

    return transformedUV;
}

// ---------------------------------------------------------------
// Mode 5: blur (contain + blurred fill)
// The image is fitted inside the screen (contain) and the leftover
// space is filled with a blurred, dimmed cover-scaled copy of the
// same image, the way TVs present vertical video.
// ---------------------------------------------------------------

// Crop (cover) UV mapping, used for the blurred backdrop
vec2 calculateCoverUV(vec2 uv, float imgWidth, float imgHeight) {
    float scale = max(ubuf.screenWidth / imgWidth, ubuf.screenHeight / imgHeight);
    vec2 scaledImageSize = vec2(imgWidth, imgHeight) * scale;
    vec2 offset = (scaledImageSize - vec2(ubuf.screenWidth, ubuf.screenHeight)) / scaledImageSize;
    return uv * (vec2(1.0) - offset) + offset * 0.5;
}

vec4 sampleBlurFill(sampler2D tex, vec2 uv, float imgWidth, float imgHeight) {
    // Background: cover-scaled copy, blurred by sampling a deep mip level.
    // The GPU has already box-filtered every mip texel, so this is a true
    // area average instead of a sparse set of taps (no starburst artefacts),
    // and it costs one texture fetch.
    float coverScale = max(ubuf.screenWidth / imgWidth, ubuf.screenHeight / imgHeight);
    // Pick the mip whose texels cover ~2% of the screen: the blur scale used
    // by TVs for pillar-boxed vertical video.
    float blurLevel = clamp(log2(max(ubuf.screenWidth, ubuf.screenHeight) * 0.02 / coverScale), 0.0, 9.0);
    vec2 backdropUV = calculateCoverUV(uv, imgWidth, imgHeight);
    vec4 background = textureLod(tex, clamp(backdropUV, 0.0, 1.0), blurLevel);
    background.rgb *= 0.62;

    // Foreground: fit (contain), centred
    float fitScale = min(ubuf.screenWidth / imgWidth, ubuf.screenHeight / imgHeight);
    vec2 fitImageSize = vec2(imgWidth, imgHeight) * fitScale;
    vec2 fitOffset = (vec2(ubuf.screenWidth, ubuf.screenHeight) - fitImageSize) * 0.5;
    vec2 fitUV = (uv * vec2(ubuf.screenWidth, ubuf.screenHeight) - fitOffset) / fitImageSize;

    // Anti-aliased edge so the contained picture has a clean border
    vec2 aa = max(fwidth(fitUV), vec2(0.00001));
    vec2 insideEdge = smoothstep(vec2(0.0) - aa, aa, fitUV) * (1.0 - smoothstep(vec2(1.0) - aa, vec2(1.0) + aa, fitUV));
    float mask = clamp(insideEdge.x * insideEdge.y, 0.0, 1.0);

    // Level 0 keeps the contained picture sharp; only the backdrop is blurred
    vec4 foreground = textureLod(tex, clamp(fitUV, 0.0, 1.0), 0.0);
    return mix(background, foreground, mask);
}

// Sample texture with fill mode and handle out-of-bounds
// If isSolid > 0.5, returns solidColor instead of sampling texture
vec4 sampleWithFillMode(sampler2D tex, vec2 uv, float imgWidth, float imgHeight, float isSolid, vec4 solidColor) {
    // Return solid color if in solid color mode
    if (isSolid > 0.5) {
        return solidColor;
    }

    // Mode 5 (blur): blurred cover backdrop behind a contained image
    if (ubuf.fillMode > 4.5) {
        return sampleBlurFill(tex, uv, imgWidth, imgHeight);
    }

    vec2 transformedUV = calculateUV(uv, imgWidth, imgHeight);

    // Mode 4 (repeat): use fract() to tile the image
    if (ubuf.fillMode > 3.5 && ubuf.fillMode < 4.5) {
        return texture(tex, fract(transformedUV));
    }

    // Check if UV is out of bounds
    if (transformedUV.x < 0.0 || transformedUV.x > 1.0 ||
        transformedUV.y < 0.0 || transformedUV.y > 1.0) {
        return ubuf.fillColor;
    }

    return texture(tex, transformedUV);
}

void main() {
    vec2 uv = qt_TexCoord0;

    // Sample textures with fill mode (handles solid colors)
    vec4 color1 = sampleWithFillMode(source1, uv, ubuf.imageWidth1, ubuf.imageHeight1, ubuf.isSolid1, ubuf.solidColor1);
    vec4 color2 = sampleWithFillMode(source2, uv, ubuf.imageWidth2, ubuf.imageHeight2, ubuf.isSolid2, ubuf.solidColor2);
    
    // Map smoothness from 0.0-1.0 to 0.001-0.5 range
    // Using a non-linear mapping for better control
    float mappedSmoothness = mix(0.001, 0.5, ubuf.smoothness * ubuf.smoothness);
    
    float edge = 0.0;
    float factor = 0.0;
    
    // Extend the progress range to account for smoothness
    // This ensures the transition completes fully at the edges
    float extendedProgress = ubuf.progress * (1.0 + 2.0 * mappedSmoothness) - mappedSmoothness;
    
    // Calculate edge position based on direction
    // As progress goes from 0 to 1, we reveal source2 (new wallpaper)
    if (ubuf.direction < 0.5) {
        // Wipe from right to left (new image enters from right)
        edge = 1.0 - extendedProgress;
        factor = smoothstep(edge - mappedSmoothness, edge + mappedSmoothness, uv.x);
        fragColor = mix(color1, color2, factor);
    } 
    else if (ubuf.direction < 1.5) {
        // Wipe from left to right (new image enters from left)
        edge = extendedProgress;
        factor = smoothstep(edge - mappedSmoothness, edge + mappedSmoothness, uv.x);
        fragColor = mix(color2, color1, factor);
    }
    else if (ubuf.direction < 2.5) {
        // Wipe from bottom to top (new image enters from bottom)
        edge = 1.0 - extendedProgress;
        factor = smoothstep(edge - mappedSmoothness, edge + mappedSmoothness, uv.y);
        fragColor = mix(color1, color2, factor);
    }
    else {
        // Wipe from top to bottom (new image enters from top)
        edge = extendedProgress;
        factor = smoothstep(edge - mappedSmoothness, edge + mappedSmoothness, uv.y);
        fragColor = mix(color2, color1, factor);
    }
    
    fragColor *= ubuf.qt_Opacity;
}