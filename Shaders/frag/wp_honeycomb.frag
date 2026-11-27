// ===== wp_honeycomb.frag =====
#version 450

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(binding = 1) uniform sampler2D source1;
layout(binding = 2) uniform sampler2D source2;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float progress;
    float cellSize;      // Size of hexagonal cells in UV space (default 0.04)
    float centerX;       // X coordinate of wave origin (0.0 to 1.0)
    float centerY;       // Y coordinate of wave origin (0.0 to 1.0)
    float aspectRatio;   // Width / Height of the screen

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

        vec2 screenPixel = uv * vec2(ubuf.screenWidth, ubuf.screenHeight);
        vec2 imagePixel = (screenPixel - offset) / scale;
        transformedUV = imagePixel / vec2(imgWidth, imgHeight);
    }
    else if (ubuf.fillMode < 3.5) {
        // Mode 3: stretch - Use original UV (stretches to fit)
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
vec4 sampleWithFillMode(sampler2D tex, vec2 uv, float imgWidth, float imgHeight, float isSolid, vec4 solidColor) {
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

    if (transformedUV.x < 0.0 || transformedUV.x > 1.0 ||
        transformedUV.y < 0.0 || transformedUV.y > 1.0) {
        return ubuf.fillColor;
    }

    return texture(tex, transformedUV);
}

// Convert cartesian to axial hex coordinates and round to nearest hex center
vec2 hexRound(vec2 axial) {
    // Convert axial (q,r) to cube (x,y,z) where x+y+z=0
    float x = axial.x;
    float z = axial.y;
    float y = -x - z;

    // Round each
    float rx = round(x);
    float ry = round(y);
    float rz = round(z);

    // Fix rounding errors by resetting the component with largest diff
    float dx = abs(rx - x);
    float dy = abs(ry - y);
    float dz = abs(rz - z);

    if (dx > dy && dx > dz) {
        rx = -ry - rz;
    } else if (dy > dz) {
        ry = -rx - rz;
    } else {
        rz = -rx - ry;
    }

    return vec2(rx, rz);
}

void main() {
    vec2 uv = qt_TexCoord0;

    // Sample both textures at original UV
    vec4 color1 = sampleWithFillMode(source1, uv, ubuf.imageWidth1, ubuf.imageHeight1, ubuf.isSolid1, ubuf.solidColor1);
    vec4 color2 = sampleWithFillMode(source2, uv, ubuf.imageWidth2, ubuf.imageHeight2, ubuf.isSolid2, ubuf.solidColor2);

    // Aspect-correct the UV for hex grid so cells appear as regular hexagons
    vec2 aspectUV = vec2(uv.x * ubuf.aspectRatio, uv.y);

    // Convert to axial hex coordinates
    // Hex grid: q axis along x, r axis at 60 degrees
    float size = max(ubuf.cellSize, 0.01);
    float q = (aspectUV.x * (2.0 / 3.0)) / size;
    float r = ((-aspectUV.x / 3.0) + (sqrt(3.0) / 3.0) * aspectUV.y) / size;

    // Round to nearest hex center
    vec2 hex = hexRound(vec2(q, r));

    // Convert hex center back to aspect-corrected UV space
    vec2 hexCenter;
    hexCenter.x = size * (3.0 / 2.0) * hex.x;
    hexCenter.y = size * (sqrt(3.0) * (hex.y + 0.5 * hex.x));

    // Calculate distance from this cell's center to the wave origin (aspect-corrected)
    vec2 origin = vec2(ubuf.centerX * ubuf.aspectRatio, ubuf.centerY);
    float dist = distance(hexCenter, origin);

    // Maximum distance from origin to any corner (for normalization)
    float maxDistX = max(ubuf.centerX * ubuf.aspectRatio, (1.0 - ubuf.centerX) * ubuf.aspectRatio);
    float maxDistY = max(ubuf.centerY, 1.0 - ubuf.centerY);
    float maxDist = length(vec2(maxDistX, maxDistY));

    // Wave expansion (same approach as disc shader):
    // Start radius behind the origin so the smoothstep zone is fully off-screen at progress=0
    float softEdge = 0.15 * maxDist;
    float totalDistance = maxDist + 2.0 * softEdge;
    float radius = -softEdge + ubuf.progress * totalDistance;

    // factor = 0 inside the wave (revealed), 1 outside (not yet reached)
    float factor = smoothstep(radius - softEdge, radius + softEdge, dist);
    float cellProgress = 1.0 - factor;

    fragColor = mix(color1, color2, cellProgress) * ubuf.qt_Opacity;
}
