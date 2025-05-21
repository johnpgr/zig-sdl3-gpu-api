[[vk::binding(0, 1)]] // Specify descriptor set 1
cbuffer Projection : register(b0)
{
    float4x4 u_projection;
};

struct Input
{
    float2 in_position : POSITION;
    float2 in_texcoord : TEXCOORD0;
};

struct Output
{
    float4 position : SV_POSITION;
    float2 texcoord : TEXCOORD0;
};

Output main(Input input)
{
    Output output;
    output.position = mul(u_projection, float4(input.in_position, 0.0, 1.0));
    output.texcoord = input.in_texcoord;
    return output;
}
