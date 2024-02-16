// ------------------------------------------------------
//
// RealHDR
// Record different brightnesses and composite HDR 
// through in-game brightness adjustments.(similar to bracketing)
//
// 通过游戏内亮度调节，记录不同亮度的画面并合成HDR。（与包围曝光相似）
// 
// Author: Lilidream, ubuntullmx@hotmail.com
// License: CC-BY-SA 4.0
//
// ------------------------------------------------------


#include "ReShade.fxh"

texture HDRDarkTexture
{
	Width = BUFFER_WIDTH;
	Height = BUFFER_HEIGHT;
	Format = RGBA8;
};

texture HDRLightTexture
{
	Width = BUFFER_WIDTH;
	Height = BUFFER_HEIGHT;
	Format = RGBA8;
};

sampler SamplerDark { Texture = HDRDarkTexture; };
sampler SamplerLight { Texture = HDRLightTexture; };

uniform int help <
	ui_text = "\n这是一个合成真HDR画面的着色器，原理与包围曝光相同，需要游戏有亮度调整功能。\n"
			  "原理是分别记录下三个亮度（偏暗、正常、偏亮）的画面并进行合成，实现HDR。\n"
			  "因此只能在画面完全静止时使用，否则会有重影！（每调整一次画面就需要重新调整一次）\n\n"
			  "此着色器一共包含三个 technique：\"记录暗部\"、\"记录亮部\"与\"合成HDR\"，三者间排列顺序可任意，但需要放在一起。\n"
			  "    1. 调整游戏内亮度到最大，能看清暗部的细节，在上方开启\"记录暗部\"一下并关闭，着色器会保存当前画面。\n"
			  "    2. 调整游戏内亮度到最小，能看清亮部的细节，在上方开启\"记录亮部\"一下并关闭，着色器会保存当前画面。\n"
			  "    3. 调整游戏内亮度到中间，恢复正常亮度，在上方开启\"合成HDR\"，就会将前面记录的亮暗画面与当前的中间值画面三者合成，得到HDR合成图。\n\n";
	ui_category = "使用前请先阅读此说明！";
	ui_label = " ";
	ui_type = "radio";
> = 0;

uniform int mode <
	ui_type = "combo";
	ui_items = "正态分布\0平均\0指数\0线性\0平方\0";
	ui_label = "合成模式";
	ui_tooltip = "按照亮度决定合成比例的权重函数。传入0~1的亮度，返回一个权重值。\n"
				 "对于某一像素，带入该像素位置在暗中明三张图的亮度，得到三个权重进行合成。\n"
				 "所有函数均为在亮度中间值 m (即下面的\"目标亮度\"参数) 时达到最大的单峰函数。\n"
				 "正态分布: exp(-(x - m)^2 / (2*\\sigma^2))\n"
				 "平均    : 1 \n"
				 "指数    : if(x>=m){ x = 2m-x } x^p\n"
				 "线性    : y=x/m when x in [0, m], y=m/(m-1)*(x-1) when x in (m, 1]\n"
				 "平方    : max(-a*(x-m)^2+1, 0)\n";
> = 0;

uniform float mu <
	ui_label = "目标亮度";
	ui_type = "slider";
	ui_min = 0; ui_max = 1;
	ui_step = 0.01;
	ui_tooltip = "HDR合成的目标亮度，可调整整体画面亮度。";
> = 0.5;

uniform float sigma <
	ui_label = "正态分布 Sigma";
	ui_type = "slider";
	ui_min = 0.01; ui_max = 2;
	ui_step = 0.01;
	ui_tooltip = "正态分布的 sigma 参数。\n值越小画面越倾倾向于目标亮度。";
	ui_category = "正态分布参数";
	ui_category_closed = true;
> = 0.6;

uniform float square_a <
	ui_label = "抛物线开口大小";
	ui_type = "slider";
	ui_min = 0; ui_max = 10;
	ui_step = 0.01;
	ui_tooltip = "a，控制抛物线开口大小。\n值越大越倾向于目标亮度。";
	ui_category = "平方参数";
	ui_category_closed = true;
> = 2;

uniform float pow_exp <
	ui_label = "指数大小";
	ui_type = "slider";
	ui_min = 0; ui_max = 5;
	ui_step = 0.01;
	ui_tooltip = "值越小，暗中明三画面混合越均匀，为0时即为平均混合。\n值越大越倾向于目标亮度。";
	ui_category = "指数参数";
	ui_category_closed = true;
> = 0.25;

void recDark(float4 pos : SV_Position, float2 texCoord : TEXCOORD, out float4 outColor : SV_Target)
{
	outColor = tex2Dfetch(ReShade::BackBuffer, texCoord * BUFFER_SCREEN_SIZE);
}

void recLight(float4 pos : SV_Position, float2 texCoord : TEXCOORD, out float4 outColor : SV_Target)
{
	outColor = tex2Dfetch(ReShade::BackBuffer, texCoord * BUFFER_SCREEN_SIZE);
}

// 计算亮度
float Y(float4 color){
    return clamp(0.3*color.x + 0.6*color.y + 0.1*color.z, 0, 1);
}

float normal_dist(float x){
	return exp(-pow(x - mu, 2)/(2*sigma*sigma));
}

float linear_dist(float x){
	// 分段函数：y=x when x/m in [0, m], y=m/(m-1)*(x-1) when x in (m, 1]
	if (x <= mu) return x/mu;
	else return mu/(mu-1)*(x-1);
}

float square_dist(float x){
	return max(-square_a*pow(x-mu, 2)+1, 0.0);
}

float pow_dist(float x){
	if(x >= mu) x = 2 * mu - x;
	return pow(x, pow_exp);
}

void hdr_composite(float4 pos : SV_Position, float2 texCoord : TEXCOORD, out float4 outColor : SV_Target){
	// 记录的暗部tex
	const float4 dark   = tex2Dfetch(SamplerDark, texCoord * BUFFER_SCREEN_SIZE);
	const float  darkY  = Y(dark);

	// 记录的亮部tex
	const float4 light  = tex2Dfetch(SamplerLight, texCoord * BUFFER_SCREEN_SIZE);
	const float  lightY = Y(light);

	// 当前的中间值
	const float4 mid    = tex2Dfetch(ReShade::BackBuffer, texCoord * BUFFER_SCREEN_SIZE);
	const float  midY   = Y(mid);

	float3 weight;
	
	if(mode == 0) weight = float3(normal_dist(darkY), normal_dist(midY), normal_dist(lightY));
	else if (mode == 1) weight = float3(1, 1, 1);
	else if (mode == 2) weight = float3(pow_dist(darkY), pow_dist(midY), pow_dist(lightY));
	else if (mode == 3) weight = float3(linear_dist(darkY), linear_dist(midY), linear_dist(lightY));
	else if (mode == 4) weight = float3(square_dist(darkY), square_dist(midY), square_dist(lightY));

	// 归一化
	weight /= (weight.x + weight.y +weight.z);
	outColor = dark * weight.x + mid * weight.y + light * weight.z;
}


technique realHDR_recordDark <
	ui_label = "RealHDR::记录暗部";
	ui_tooltip = "激活再关闭后，会记录下关闭时的画面。用于合成HDR画面。";
>
{
	pass
	{
		VertexShader = PostProcessVS;
		PixelShader = recDark;
		RenderTarget = HDRDarkTexture;
	}
}

technique realHDR_recordLight <
	ui_label = "RealHDR::记录亮部";
	ui_tooltip = "激活再关闭后，会记录下关闭时的画面。用于合成HDR画面。";
>
{
	pass
	{
		VertexShader = PostProcessVS;
		PixelShader = recLight;
		RenderTarget = HDRLightTexture;
	}
}

technique realHDR <
	ui_label = "RealHDR::合成HDR";
	ui_tooltip = "通过在游戏内调节画面亮度，记录下不同亮度画面并合成HDR。\n作者：Lilidream";
>
{

	pass
	{
		VertexShader = PostProcessVS;
		PixelShader = hdr_composite;
	}
}