#include <metal_stdlib>
using namespace metal;

struct KeyParams {
	float threshold;   // clip level: luma below this = fully transparent
	float softness;    // gain level: luma above this = fully opaque
	float invert;      // 0.0 = black bg (normal), 1.0 = white bg (inverted)
};

kernel void lumaKeyExtract(
	texture2d<float, access::read>  inTexture  [[texture(0)]],
	texture2d<float, access::write> fillOut    [[texture(1)]],
	texture2d<float, access::write> keyOut     [[texture(2)]],
	constant KeyParams& params                 [[buffer(0)]],
	uint2 gid                                  [[thread_position_in_grid]]
) {
	if (gid.x >= inTexture.get_width() || gid.y >= inTexture.get_height()) {
		return;
	}

	float4 pixel = inTexture.read(gid);

	// Rec.709 luma
	float luma = dot(pixel.rgb, float3(0.2126, 0.7152, 0.0722));

	// Invert for white background keying
	if (params.invert > 0.5) {
		luma = 1.0 - luma;
	}

	// Linear clip/gain remap — preserves gradient linearity.
	// clip (threshold): luma <= clip → matte = 0 (transparent)
	// gain (softness):  luma >= gain → matte = 1 (opaque)
	// Between clip and gain: linear ramp
	float clip = params.threshold;
	float gain = max(clip + 0.001, params.softness);  // gain must be > clip
	float matte = saturate((luma - clip) / (gain - clip));

	// Fill: pass through original pixel
	fillOut.write(pixel, gid);

	// Key: grayscale matte (white = opaque, black = transparent)
	keyOut.write(float4(matte, matte, matte, 1.0), gid);
}
