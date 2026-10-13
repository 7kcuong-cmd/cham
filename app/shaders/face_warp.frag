#version 320 es
// Nhọn cằm + mắt to bằng cách dồn điểm lấy mẫu (liquify nhẹ). Mọi toạ độ là 0..1 theo ô hiển thị.
precision highp float;

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;       // kích thước ô (px)
uniform vec2 uLeftEye;
uniform vec2 uRightEye;
uniform vec2 uChin;
uniform vec2 uFaceC;
uniform float uFaceHalfW; // nửa bề rộng mặt (theo trục X, 0..1)
uniform float uEyeR;      // bán kính vùng mắt (theo trục Y, 0..1)
uniform float uEyeAmt;    // 0..1
uniform float uChinAmt;   // 0..1
uniform sampler2D uTex;

out vec4 fragColor;

// Phóng to quanh tâm c: điểm gần tâm lấy mẫu từ gần tâm hơn.
vec2 bulge(vec2 p, vec2 c, float r, float amt, float aspect) {
  vec2 d = p - c;
  d.x *= aspect;
  float dist = length(d);
  if (dist >= r || amt <= 0.0) return p;
  float t = dist / r;
  float k = 1.0 - amt * (1.0 - t * t) * (1.0 - t * t);
  vec2 q = c + (p - c) * k;
  return q;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  float aspect = uSize.x / uSize.y;
  vec2 src = uv;

  if (uEyeAmt > 0.0) {
    src = bulge(src, uLeftEye, uEyeR, uEyeAmt * 0.55, aspect);
    src = bulge(src, uRightEye, uEyeR, uEyeAmt * 0.55, aspect);
  }

  if (uChinAmt > 0.0) {
    // Vùng hàm: từ khoảng 1/3 chiều cao mặt phía trên cằm xuống chút dưới cằm.
    float jawTop = mix(uFaceC.y, uChin.y, 0.35);
    float yw = smoothstep(jawTop, uChin.y, src.y) * (1.0 - smoothstep(uChin.y, uChin.y + 0.06, src.y));
    float dx = (src.x - uFaceC.x);
    // chỉ tác động quanh mặt, mờ dần ra ngoài
    float xw = 1.0 - smoothstep(uFaceHalfW * 1.1, uFaceHalfW * 1.9, abs(dx));
    float k = uChinAmt * 0.22 * yw * xw;
    src.x = uFaceC.x + dx * (1.0 + k);
  }

  fragColor = texture(uTex, clamp(src, vec2(0.0), vec2(1.0)));
}
