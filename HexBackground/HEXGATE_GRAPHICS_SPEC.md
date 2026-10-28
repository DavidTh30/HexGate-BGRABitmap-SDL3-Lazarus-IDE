# HexGate Graphics — Technical Specification (v1)

เอกสารนี้บันทึก **ทุกรายละเอียด** ของระบบกราฟิก HexGate ทั้งสองแบบที่สร้างไว้ เพื่อให้นำไปเขียนใหม่ด้วยภาษาอื่น (C/C++, C#, Rust, Python, JavaScript/WebGL, Unity, Godot ฯลฯ) ได้ผลเหมือนเดิม

| ระบบ | โฟลเดอร์ | วิธีวาด | แสดงผล |
|---|---|---|---|
| **HexGate Editor** (และเกม HexGate) | `HexGate Editor\`, `HexGate\` | BGRABitmap + rasterizer ของเราเอง บน CPU ทุก core (tile ละ 16 แถว) | OpenGL texture 1 ใบ + vsync (`wglSwapIntervalEXT(1)`) |
| **HexGate Simulator** (และ HexGate SDL3) | `HexGate Simulator\`, `HexGate SDL3\` | engine เดียวกันสร้าง draw list บน CPU แล้ว GPU วาดผ่าน SDL3 renderer | SDL3 + vsync (`SDL_SetRenderVSync(1)`) |

ทั้งสองระบบใช้ **engine ตัวเดียวกัน** (`uhexbackground.pas`) สำหรับโลก กล้อง ความลึก การเลือก sprite และลำดับการวาด ต่างกันเฉพาะ **ขั้นสุดท้าย** คือการผสมพิกเซล (CPU rasterizer หรือ GPU)

ข้อมูลประกอบที่ต้องใช้คู่กับเอกสารนี้: **`hexgate_graphics.json`** (format `hexgate-graphics` v1) มีค่าตั้งทุกค่า สูตร sprite atlas ภาพ background/vignette และ reference frame (ดูหัวข้อ 14)

> ภาษาในเอกสาร: คำอธิบายเป็นภาษาไทย สูตร ชื่อตัวแปร และ pseudo-code เป็นภาษาอังกฤษ เพื่อนำไปใช้ในโค้ดได้ตรง ๆ
> ตัวเลขทั้งหมดอ้างจากซอร์สโค้ดจริง (FPC 3.2.2 + BGRABitmap 11.6.2) ณ วันที่ 2026-10-14

---

## สารบัญ

0. [ลำดับการพอร์ตที่แนะนำ](#0-ลำดับการพอร์ตที่แนะนำ)
1. [ระบบพิกัด หน่วย และกติกาตัวเลข](#1-ระบบพิกัด-หน่วย-และกติกาตัวเลข)
2. [ค่าตั้ง (Settings) และการ invalidate cache](#2-ค่าตั้ง-settings-และการ-invalidate-cache)
3. [ตัวเลขสุ่มแบบกำหนดได้: hash, noise, RNG](#3-ตัวเลขสุ่มแบบกำหนดได้-hash-noise-rng)
4. [กล้อง](#4-กล้อง)
5. [โลก: แผ่นรังผึ้ง (sheets) และประตู (gates)](#5-โลก-แผ่นรังผึ้ง-sheets-และประตู-gates)
6. [อนุภาค: bokeh dust และ sparks](#6-อนุภาค-bokeh-dust-และ-sparks)
7. [ฟังก์ชันความลึก: CoC, fade](#7-ฟังก์ชันความลึก-coc-fade)
8. [การสร้างเฟรม (BuildFrame) และ draw list](#8-การสร้างเฟรม-buildframe-และ-draw-list)
9. [Sprites: สูตรวาด, quantisation, cache](#9-sprites-สูตรวาด-quantisation-cache)
10. [Screen layers: background และ vignette](#10-screen-layers-background-และ-vignette)
11. [Backend A — CPU rasterizer + OpenGL (HexGate Editor)](#11-backend-a--cpu-rasterizer--opengl-hexgate-editor)
12. [Backend B — SDL3 GPU (HexGate Simulator)](#12-backend-b--sdl3-gpu-hexgate-simulator)
13. [การจำลองการบิน (autopilot) และ game loop](#13-การจำลองการบิน-autopilot-และ-game-loop)
14. [รูปแบบไฟล์ hexgate-graphics v1](#14-รูปแบบไฟล์-hexgate-graphics-v1)
15. [พฤติกรรมของโปรแกรมแก้ไข (Editor / Simulator)](#15-พฤติกรรมของโปรแกรมแก้ไข-editor--simulator)
16. [การตรวจสอบผลการพอร์ต และข้อจำกัดที่ทราบ](#16-การตรวจสอบผลการพอร์ต-และข้อจำกัดที่ทราบ)
17. [ประสิทธิภาพที่วัดได้](#17-ประสิทธิภาพที่วัดได้)
- [ภาคผนวก A — ค่าตั้งทั้ง 121 ค่า](#ภาคผนวก-a--ค่าตั้งทั้ง-121-ค่า)
- [ภาคผนวก B — โครงสร้างข้อมูลภายใน engine](#ภาคผนวก-b--โครงสร้างข้อมูลภายใน-engine)
- [ภาคผนวก C — ข้อมูลเกม (game.*)](#ภาคผนวก-c--ข้อมูลเกม-game)
- [ภาคผนวก D — แผนที่ไฟล์ซอร์ส](#ภาคผนวก-d--แผนที่ไฟล์ซอร์ส)

---

## 0. ลำดับการพอร์ตที่แนะนำ

1. **อ่านไฟล์** `hexgate_graphics.json` (หัวข้อ 14) แล้วโหลด `settings` ลง struct ตามภาคผนวก A
2. **hash / noise / RNG** (หัวข้อ 3) ต้องตรงทุกบิต เพราะโลกทั้งหมดสร้างจาก seed
3. **กล้อง + projection** (หัวข้อ 4)
4. **sheets + gates** (หัวข้อ 5): ทดสอบด้วยการพิมพ์จำนวน cell ต่อ sheet เทียบกับต้นฉบับ
5. **วาดแบบง่ายก่อน**: ใช้ sprite จาก **atlas** ในไฟล์ (ATLAS mode, หัวข้อ 12.5) จะได้ภาพทันทีโดยยังไม่ต้องเขียนสูตร sprite
6. **draw list** (หัวข้อ 8) และ blending แบบ premultiplied
7. **สูตร sprite** (หัวข้อ 9) ถ้าต้องการให้แก้ค่าแล้วภาพเปลี่ยนได้ (RECIPE mode)
8. **อนุภาค** (หัวข้อ 6), background/vignette (หัวข้อ 10)
9. **autopilot** (หัวข้อ 13)
10. **เทียบ** กับ `reference_frame` และภาพ atlas (หัวข้อ 16)

ถ้าใช้ GPU (WebGL, Vulkan, D3D, Unity, Godot) ให้ทำตาม Backend B (หัวข้อ 12) ถ้าใช้ CPU ให้ทำตาม Backend A (หัวข้อ 11)

---

## 1. ระบบพิกัด หน่วย และกติกาตัวเลข

| สิ่ง | กติกา |
|---|---|
| โลก (world) | `x` ขวา, `y` **ลง**, `z` ไปข้างหน้า (เข้าจอ) กล้องบินไปทาง `+z` |
| หน่วยโลก | 1 หน่วย = รัศมีหกเหลี่ยม (`hexagon_field.hex_radius` = 1 โดยปริยาย) |
| จอ (screen) | พิกเซล, จุดเริ่มซ้ายบน, `x` ขวา `y` ลง |
| ตำแหน่งพิกเซล | **CPU rasterizer**: พิกเซลดัชนี `(x, y)` ถือว่าอยู่ที่พิกัด `(x, y)` (ไม่บวก 0.5) **GPU**: ต้องเลื่อน quad `+0.5` เพื่อให้จุดศูนย์กลาง texel ตรงกัน (หัวข้อ 12.3) |
| สี | `[r, g, b, a]` 0..255 ในไฟล์ ใน engine เก็บเป็น BGRA 8 บิต (`TBGRAPixel`, ลำดับในหน่วยความจำ B,G,R,A) |
| alpha ในค่าตั้ง | ค่าชื่อ `*_alpha` บางตัวเป็น 0..255 (เช่น `rim_alpha`, `face_alpha`, `vignette.strength`) บางตัวเป็นตัวคูณ 0..1 (เช่น `back_alpha`, `inner_alpha`) ดูช่วง min/max ในภาคผนวก A |
| มุม | ค่าตั้งเป็น **องศา** สูตรใช้ radian: `rad(x) = x * pi / 180` |
| ชนิดตัวเลข | engine ใช้ `single` (float32) เกือบทั้งหมด เวลา (`time`) เป็น `double` |
| `Round` | Pascal `Round` = **banker's rounding** (ปัดครึ่งไปเลขคู่: `Round(2.5)=2`, `Round(3.5)=4`) ใช้ตอนแปลงจำนวนอนุภาค (`Round(count)`) และค่า alpha |
| `Floor`/`Ceil` | ตามคณิตศาสตร์ปกติ (ไปทาง −∞ / +∞) |
| `div`, `shr` | หารจำนวนเต็มตัดเศษ / shift ขวาแบบไม่มีเครื่องหมาย |
| `SarLongint(x, 16)` | arithmetic shift ขวา (รักษาเครื่องหมาย) = `floor(x / 65536)` |
| `EnsureRange(v, a, b)` | `clamp(v, a, b)` |
| `smoothstep(e0, e1, x)` | ถ้า `e0 = e1`: `x >= e0 ? 1 : 0` มิฉะนั้น `t = clamp((x-e0)/(e1-e0), 0, 1); t*t*(3-2t)` (รองรับ `e0 > e1` คือกลับด้าน) |

หกเหลี่ยมเป็นแบบ **flat-top**: มุมที่ `i = 0..5` อยู่ที่ `(cx + r*cos(i*60°), cy + r*sin(i*60°))` (มุม 0 อยู่ขวาสุด, y ลง จึงเรียงตามเข็มนาฬิกาบนจอ)

---

## 2. ค่าตั้ง (Settings) และการ invalidate cache

- engine มีค่าตั้ง **121 ค่า** (float 104 + สี 17) แบ่ง 12 กลุ่ม: Camera, Depth of field, Fog, Hexagon field, Hexagon style, Glow, Background, Bokeh dust, Sparks, Vignette, Game, Performance (โปรแกรมแก้ไขเพิ่มกลุ่มที่ 13 "Game rules (autopilot)" สำหรับตัวเลข `game.*` 11 ค่า)
- รายการเต็ม พร้อม key ในไฟล์ ชื่อ field ใน engine ค่าใน HexGate ค่า default ของ engine ช่วงค่า และความหมาย: **ภาคผนวก A**
- **ค่าใน HexGate ≠ ค่า default ของ engine** เพราะเกมปรับบางค่าตอนเริ่ม (`game.look_overrides`, ภาคผนวก C.5) และตั้ง `camera.speed` เอง ค่าในไฟล์คือค่าที่เกมใช้จริง

### 2.1 ผลของการเปลี่ยนค่า (`rebuilds`)

แต่ละค่ามีรายการ cache ที่ต้องสร้างใหม่เมื่อค่าเปลี่ยน (ในไฟล์คือ `settings.<key>.rebuilds`):

| rebuild | สิ่งที่ทำ |
|---|---|
| (ว่าง = `live`) | ไม่ต้องทำอะไร ค่าถูกอ่านทุกเฟรม |
| `sprites` | ล้าง sprite cache ทั้งหมด (หัวข้อ 9.4) — `ivSprites` |
| `screen_layers` | ล้าง background/vignette cache (หัวข้อ 10) — `ivScreen` |
| `world` | ทิ้ง sheets ทั้งหมด (สร้างใหม่จาก seed เมื่อต้องใช้) — ใน engine เรียก `ivField` |
| `dust` | สร้าง dust ใหม่ทั้งหมด |
| `sparks` | สร้าง sparks ใหม่ทั้งหมด |

`Invalidate(set)`:
```text
if sprites in set:       clear sprite cache
if screen_layers in set: clear screen caches
if world in set:         sheets = []
if world or dust or sparks in set:
    rng = uint32(seed * 2654435761 + 1); if rng == 0: rng = 1      # RNG กลับไปจุดเริ่ม
    UpdateCamera()
    if dust in set:   dust = []
    if sparks in set: sparks = []
    InitParticles()        # สร้างเฉพาะชุดที่ว่าง: dust ก่อน แล้ว sparks
```
`SetSeed(s)`: ถ้า seed เปลี่ยน ให้ `Invalidate({world, dust, sparks})`
`ResetDefaults()`: ค่าทั้งหมดกลับเป็น default แล้ว `Invalidate(ทั้งหมด)`

ในโปรแกรมแก้ไข การ invalidate ถูกหน่วงไว้ **150 ms หลังการแก้ค่าครั้งสุดท้าย** (debounce) เพื่อให้ลาก slider ได้ลื่น (หัวข้อ 15)

---

## 3. ตัวเลขสุ่มแบบกำหนดได้: hash, noise, RNG

ทุกอย่างในโลกสร้างจาก `seed` (ค่า default **2026**) พอร์ตให้ตรงทุกบิตแล้วโลกจะเหมือนเดิมทุก cell

### 3.1 `hashf(a, b, c, d) -> [0, 1)`
คณิตศาสตร์ uint32 ที่ล้นแล้ววนกลับ (wrap-around) ทั้งหมด:
```c
float hashf(int32 a, int32 b, int32 c, int32 d) {
    uint32 h = (uint32)a * 73856093u ^ (uint32)b * 19349663u
             ^ (uint32)c * 83492791u ^ (uint32)d * 2654435761u;
    h ^= h >> 16;  h *= 0x7FEB352Du;
    h ^= h >> 15;  h *= 0x846CA68Bu;
    h ^= h >> 16;
    return (float)((double)h / 4294967296.0);   // เก็บเป็น float32
}
```
ข้อควรระวัง: ผลถูกเก็บเป็น **float32** ค่า `h` ที่ใกล้ 2^32 จะปัดเป็น `1.0` ได้ (ต้นฉบับก็เป็นเช่นนั้น) การเปรียบเทียบ `h < p` จึงต้องใช้ float32 เหมือนกัน

### 3.2 Value noise 3 มิติ
```text
noise(x, y, z, seed):
    xi, yi, zi = floor(x), floor(y), floor(z)
    fx, fy, fz = x - xi, y - yi, z - zi
    fx = fx*fx*(3-2fx); fy = ...; fz = ...
    a = lerp(hashf(xi,yi,zi,seed),     hashf(xi+1,yi,zi,seed),     fx)
    b = lerp(hashf(xi,yi+1,zi,seed),   hashf(xi+1,yi+1,zi,seed),   fx)
    c = lerp(hashf(xi,yi,zi+1,seed),   hashf(xi+1,yi,zi+1,seed),   fx)
    d = lerp(hashf(xi,yi+1,zi+1,seed), hashf(xi+1,yi+1,zi+1,seed), fx)
    a = lerp(a, b, fy); c = lerp(c, d, fy)
    return lerp(a, c, fz)                       # lerp(p, q, t) = p + (q - p) * t

cluster(x, y, z):   s = hexagon_field.noise_scale
    0.65 * noise(x*s, y*s, z*s, seed) + 0.35 * noise(x*s*2.1 + 17, y*s*2.1 + 5, z*s*2.1, seed + 1)
```

### 3.3 RNG ของอนุภาค (xorshift32)
```text
state: uint32, เริ่มที่ uint32(seed * 2654435761 + 1) (ถ้าได้ 0 ให้เป็น 1) — ตั้งใหม่ทุกครั้งที่ Invalidate world/dust/sparks
rnd():  state ^= state << 13; state ^= state >> 17; state ^= state << 5
        return float32(state / 4294967296.0)
randRange(a, b) = a + rnd() * (b - a)
```
ลำดับการเรียก `rnd()` มีผลกับผลลัพธ์ ลำดับที่แน่นอนอยู่ในหัวข้อ 6

ส่วนตำแหน่งช่องของประตูใน autopilot ใช้ `Random` ธรรมดาของภาษา (ไม่กำหนดได้) ดูหัวข้อ 13

---

## 4. กล้อง

### 4.1 สถานะ
`cam = (x, y, z)`, `yaw`, `pitch`, `roll`, `focus` (ระยะโฟกัสปัจจุบัน), `time` (วินาที, double), `steerYaw`, `steerPitch`, `mouse = (mx, my)` ใน [-1, 1]

เริ่มต้น: ทุกค่าเป็น 0 (`cam.z = 0`, `time = 0`)

### 4.2 `UpdateCamera()`
```text
w = 2*pi*time
if manual (เกม/autopilot ควบคุม):
    cam.x, cam.y, yaw, pitch, roll = ค่าที่ SetManualCamera ให้มา
else (free flight):
    cam.x = sway_x * sin(w * sway_freq)
    cam.y = sway_y * sin(w * sway_freq * 0.73 + 1.3)
    yaw   = rad(look_yaw)   * sin(w * look_freq)              + steerYaw
    pitch = rad(look_pitch) * sin(w * look_freq * 0.81 + 0.7) + steerPitch
    roll  = rad(camera.roll) * sin(w * look_freq * 0.57 + 2.1)
if focusOverride > 0: focus = focusOverride
else: focus = max(0.3, focus_distance + focus_pull * sin(w * focus_pull_freq))
เก็บ sin/cos ของ yaw, pitch, roll ไว้ใช้
```
`SetManualCamera(x, y, yaw, pitch, roll)` เปิดโหมด manual ถาวร

### 4.3 World → camera space
```text
d = p - cam
x1 =  d.x*cos(yaw) - d.z*sin(yaw);   z1 = d.x*sin(yaw) + d.z*cos(yaw)
y2 =  d.y*cos(pitch) + z1*sin(pitch); z2 = -d.y*sin(pitch) + z1*cos(pitch)
xc =  x1*cos(roll) - y2*sin(roll);    yc = x1*sin(roll) + y2*cos(roll);   zc = z2
```

### 4.4 Projection
```text
f  = (H / 2) / tan(rad(field_of_view) / 2)     # H = ความสูงเฟรม (render size), fov แนวตั้ง
sx = W/2 + f * xc / zc
sy = H/2 + f * yc / zc
radius_px = f * R / zc
มองเห็นเมื่อ zc > near_clip (บางจุดใช้ zc >= near_clip ดูหัวข้อ 8)
```

### 4.5 `Animate(dt)` — ลำดับต่อเฟรม (ต้องตรงลำดับนี้)
```text
time += dt
ลบ gates ตัวหน้าสุดที่ gate.z < cam.z - 2 (ลบจากต้นรายการเท่านั้น)
cam.z += camera.speed * dt
k = min(1, dt * mouse_smooth)
steerYaw   += (mx * rad(mouse_steer) - steerYaw) * k
steerPitch += (-my * rad(mouse_steer) * 0.6 - steerPitch) * k
UpdateCamera(); UpdateField(); InitParticles()
for each dust D:  zr = D.z - cam.z
    if zr < focus_distance*0.8 or zr > far_clip*1.05: SpawnDust(D, anywhere = (zr > far_clip*1.05))
for each spark S:
    S.life += dt * S.lifeSpeed
    S.y -= S.rise * dt
    S.x += cos(time*0.7 + S.phase) * sparks.sway * dt
    zr = S.z - cam.z
    if S.life >= 1 or zr < near_clip*2 or zr > far_clip: SpawnSpark(S, anywhere = false)
```
หมายเหตุ: dust ใช้ค่าตั้ง `focus_distance` (ไม่ใช่ focus ปัจจุบัน) และ dust ไม่เคลื่อนที่ในโลก (กล้องบินผ่าน)

---

## 5. โลก: แผ่นรังผึ้ง (sheets) และประตู (gates)

### 5.1 Mask แนวทแยง
```text
s = 2 * layout_distance * tan(rad(fov) / 2)
t(x, y) = y / s - (edge_offset - edge_slope * x / s)      # > 0 = อยู่ในพื้นที่ (ล่างขวา)
```

### 5.2 ช่วงของ sheets ที่ต้องมี (`UpdateField`)
```text
kMin = floor((cam.z + near_clip - thickness - z_jitter * sheet_gap) / sheet_gap)
kMax = ceil((cam.z + far_clip) / sheet_gap)
ลบ sheets ที่ k < kMin ออกจากต้นรายการ
เพิ่ม sheet ต่อท้ายตั้งแต่ (k สุดท้าย + 1 หรือ kMin ถ้าว่าง) ถึง kMax
```

### 5.3 `GenerateSheet(k)` — ทุกบรรทัดสำคัญ
```text
tanH = tan(rad(fov)/2)
Ex = far_clip * (tanH*2    + tan(rad(min(80, look_yaw   + mouse_steer))))       + sway_x + 2*hex_radius
Ey = far_clip * (tanH*1.05 + tan(rad(min(80, look_pitch + mouse_steer*0.6)))) + sway_y + 2*hex_radius
r  = hex_radius;  dx = 1.5 * r * cell_gap;  dy = sqrt(3) * r * cell_gap
ox = hashf(k, 11, 0, seed) * dx;  oy = hashf(k, 12, 0, seed) * dy
z0 = k * sheet_gap
for col = floor((-Ex-ox)/dx) .. ceil((Ex-ox)/dx):            # col เป็นวงนอก
  for row = floor((-Ey-oy)/dy) - 1 .. ceil((Ey-oy)/dy):
    x = ox + col*dx;  y = oy + row*dy;  if col is odd: y += dy/2      # (col and 1) = 1, รวมเลขลบ
    h[i] = hashf(col, row, k, seed*8 + i)  for i = 0..6
    if corridor_radius > 0 and x² + y² < corridor_radius²: skip
    t = t(x, y)
    p = smoothstep(fade_start, fade_end, t) * density
        * (cluster_min + (1 - cluster_min) * smoothstep(cluster_low, cluster_high, cluster(x, y, z0)))
    loose = false
    if h0 >= p:
        if -loose_zone < t < 0.05 and h1 < loose_chance: loose = true
        else: skip
    cell.x = x; cell.y = y
    cell.z = z0 + (h2 - 0.5) * z_jitter * sheet_gap
    cell.R = r * (1 - size_jitter*0.7 + h3*size_jitter)
    if loose:
        d = r * (0.5 + h4 * loose_drift)
        cell.x -= d*0.6; cell.y -= d*0.8
        cell.R *= 1 - loose_shrink * h5
        cell.z += (h6 - 0.5) * sheet_gap * 0.5
```
หมายเหตุ: ขนาด Ex/Ey ใช้ค่ากล้องตอนสร้าง ถ้าเปลี่ยน fov/far_clip/look ต้อง invalidate `world` (ค่าเหล่านี้มี rebuild `world` อยู่แล้ว)

### 5.4 ประตู (`AddGate(Z, GX, GY, GR)`)
```text
r = hex_radius;  dx = 1.5*r*cell_gap;  dy = sqrt(3)*r*cell_gap
ext = corridor_radius + 4*r                                  # รัศมีของแผ่นประตู
for col = floor(-ext/dx) - 1 .. ceil(ext/dx) + 1:
  for row = floor(-ext/dy) - 1 .. ceil(ext/dy) + 1:
    x = col*dx; y = row*dy; if col odd: y += dy/2           # ไม่มี offset แบบ sheet
    if x² + y² > ext²: skip
    d = dist((x, y), (GX, GY))
    if d < GR + 0.85r: skip                                  # ช่องที่ให้ลอด
    cell = (x, y, Z, R = 0.96r)
    kind = (d < GR + 2.4r) ? 2 (ขอบช่อง: sprite gate_edge) : 1 (ผนัง: sprite gate)
```
ประตูถูกลบเมื่อ `gate.z < cam.z - 2` (ใน Animate) `ClearGates()` ลบทั้งหมด

---

## 6. อนุภาค: bokeh dust และ sparks

`InitParticles()`: ถ้า dust ว่าง ให้สร้าง `Round(bokeh_dust.count)` ตัวด้วย `SpawnDust(anywhere=true)` ตามลำดับ แล้วถ้า sparks ว่าง ให้สร้าง `Round(sparks.count)` ตัวด้วย `SpawnSpark(anywhere=true)`

### 6.1 `SpawnDust(D, anywhere)` — ลำดับเรียก RNG
```text
tanH = tan(rad(fov)/2); tries = 0
repeat:
    zr = anywhere ? randRange(focus_distance*1.2, far_clip) : randRange(far_clip*0.8, far_clip)
    x = cam.x + (rnd()*2 - 1) * tanH * 1.8 * zr
    y = cam.y + (rnd()*2 - 1) * tanH * zr
    tries += 1
until rnd() < 0.25 + 0.75 * exp(-(t(x, y) / 0.3)²)  or  tries > 30     # rnd() ถูกเรียกเสมอก่อนเช็ค tries
D.pos = (x, y, cam.z + zr)
D.dot   = rnd() < dot_chance
D.size  = randRange(size_min, size_max);  if dot: size *= dot_size
D.alpha = randRange(alpha_min, alpha_max); if dot: alpha = min(255, alpha * 2.5)
```

### 6.2 `SpawnSpark(S, anywhere)`
```text
repeat:
    zr = randRange(max(near_fade_start, focus_distance*0.4), focus_distance*2.5)
    x = cam.x + (rnd()*2 - 1) * tanH * 1.8 * zr
    y = cam.y + (rnd()*2 - 1) * tanH * zr
    tries += 1
until rnd() < (1 - field_bias) + field_bias * smoothstep(fade_start - 0.05, fade_end + 0.1, t(x, y))  or  tries > 30
S.pos = (x, y, cam.z + zr)
S.size = randRange(size_min, size_max)
S.alpha = randRange(alpha_min, alpha_max)
S.phase = rnd() * 2*pi
S.twinkle = randRange(twinkle_min, twinkle_max)
S.rise = randRange(rise_min, rise_max)
S.lifeSpeed = 1 / max(0.1, randRange(life_min, life_max))
S.life = anywhere ? rnd() : 0
```
(`fade_start`, `fade_end` คือ `hexagon_field.fade_start/end`; `near_fade_start` คือ `fog.near_fade_start`)

---

## 7. ฟังก์ชันความลึก: CoC, fade

```text
coc(z, H)  = min(max_blur * H / 1000, aperture * H / 100 * |z - focus| / z)      # px, z = camera-space z
fade(z)    = (1 - smoothstep(fog_start, fog_end, z)) * smoothstep(near_fade_end, near_fade_start, z)
gate fade  = (1 - smoothstep(fog_start, fog_end, z)) * smoothstep(2.2, 5.0, z)     # ผนังประตูจางก่อนถึงกล้อง
```

---

## 8. การสร้างเฟรม (BuildFrame) และ draw list

engine แยก "ตัดสินใจ" (serial, CPU) ออกจาก "ผสมพิกเซล" (backend) ผลของ BuildFrame คือ **draw list** เรียงจากไกลไปใกล้ ซึ่ง backend ทั้งสองแบบวาดตามลำดับเดียวกัน

### 8.1 Passes (เปิด/ปิดได้)
| id | ชื่อ | ใช้ทำ |
|---|---|---|
| 0 | Background | ภาพพื้นหลัง (ถ้าปิด: เติมดำ หรือลายหมากรุก) |
| 1 | Bokeh dust | dust/dot sprites |
| 2 | Hex back faces | ด้านหลังของหกเหลี่ยม |
| 3 | Hex side edges | เส้นขอบด้านข้าง 6 เส้น |
| 4 | Hex glow | แสงเรือง (รวมอยู่ใน sprite `front_glow` เมื่อเปิดทั้ง 4 และ 5) |
| 5 | Hex front faces | หน้าหกเหลี่ยม |
| 6 | Sparks | ประกายไฟ |
| 7 | Vignette | ขอบมืด |

โปรแกรมทั้งสองเปิดทุก pass

### 8.2 ขั้นตอน
```text
W = max(W, 8); H = max(H, 8)
if sheets empty: UpdateField();  InitParticles()
if sprite cache bytes > cache_mb * 1048576: clear sprite cache
CollectBuiltSprites()                                  # รับ sprite จาก thread (หัวข้อ 9.5)
budgetEnd = live view ? now + sprite_budget_ms : infinity
f = (H/2) / tan(rad(fov)/2)
screen = GetScreen(W, H)                               # background/vignette ของขนาดนี้
cmds = []

# 1 dust
for D in dust:
    V = toCamera(D.pos); if V.z < near_clip: continue
    a = D.alpha/255 * fade(V.z) * smoothstep(focus_distance*0.8, focus_distance*1.3, V.z)
    if a < 0.01: continue
    rp = f * D.size / V.z
    blur = max(coc(V.z, H), min_blur * H / 1000)
    spr, scale = GetSprite(D.dot ? dot : dust, rp, blur)
    AddBlit(pass 1, spr, W/2 + f*V.x/V.z, H/2 + f*V.y/V.z, scale, a)

# 2..5 หกเหลี่ยม
CollectItems(W, H, f)          # 8.3
sort items by z descending (ไกลก่อน)           # quicksort, ไม่ stable
for it in items:
    if it.BR > 0.3:
        spr, sc = GetSprite(it.kind == 0 ? back : gate_back, it.BR, it.blur)
        AddBlit(pass 2, spr, it.BX, it.BY, sc, it.opa)
    if it.BR > 0.3 and it.R > 5 and it.blur < side_max_blur * H / 1000:
        lw = max(1, it.R * line_width * 0.7)
        for k = 0..5:  c = cos(k*60°), s = sin(k*60°)
            AddLine(pass 3, it.SX + it.R*c, it.SY + it.R*s, it.BX + it.BR*c, it.BY + it.BR*s,
                    lw, back_colour, rim_alpha * side_alpha * it.opa)        # alpha หน่วย 0..255
    if front pass on:
        kind = it.kind==1 ? gate : it.kind==2 ? gate_edge : (glow pass on ? front_glow : front)
        spr, sc = GetSprite(kind, it.R, it.blur); AddBlit(pass 5, spr, it.SX, it.SY, sc, it.opa)
    elif glow pass on:
        spr, sc = GetSprite(glow, it.R, it.blur); AddBlit(pass 4, spr, it.SX, it.SY, sc, it.opa)

# 6 sparks
for S in sparks:
    V = toCamera(S.pos); if V.z < near_clip: continue
    a = S.alpha * sin(pi * S.life) * fade(V.z) * ((1 - twinkle_depth) + twinkle_depth * sin(time * S.twinkle + S.phase))
    if a < 3: continue                                  # a หน่วย 0..255
    rp = max(0.3, f * S.size / V.z);  blur = coc(V.z, H)
    x = W/2 + f*V.x/V.z;  y = H/2 + f*V.y/V.z
    if x < -blur-10 or x > W+blur+10 or y < -blur-10 or y > H+blur+10: continue
    if blur > rp*2:
        AddDisc(pass 6, x, y, blur, halo_colour, max(a*0.05, a * (rp*2/blur)² * 0.4))
    else:
        AddDisc(pass 6, x, y, rp * halo_size, halo_colour, a * halo_alpha)
        AddDisc(pass 6, x, y, rp, core_colour, a)
jobBase = pass 0 on;  jobVig = pass 7 on
```

### 8.3 `CollectItems` — การเลือกหกเหลี่ยมที่จะวาด
```text
FindOccluder():                    # ผนังประตูทึบที่ใกล้ที่สุด ใช้บังสิ่งที่อยู่ข้างหลัง
    for g in gates (ตามลำดับ z จากใกล้ไปไกล):
        V = toCamera(0, 0, g.z)
        if V.z < 5.5: continue                          # กำลังจางอยู่
        if V.z > fog_start: stop (ไม่มี occluder)
        occZ = V.z
        wall = (W/2 + f*V.x/V.z, H/2 + f*V.y/V.z), wallR = f * (g.ext - 1.5*hex_radius) / V.z
        V = toCamera(g.GX, g.GY, g.z)
        hole = (W/2 + f*V.x/V.z, H/2 + f*V.y/V.z), holeR = f * (g.GR + hex_radius) / V.z
        occ = true; stop

Consider(cell, kind, nearStart, nearEnd):     # sheets: (fog.near_fade_start, fog.near_fade_end); gates: (5.0, 2.2)
    V = toCamera(cell); if V.z < near_clip: cull
    op = (1 - smoothstep(fog_start, fog_end, V.z)) * smoothstep(nearEnd, nearStart, V.z)
    if op < 0.02: cull
    rp = f * cell.R / V.z;  sx = W/2 + f*V.x/V.z;  sy = H/2 + f*V.y/V.z
    cb = coc(V.z, H)
    pad = rp * (1.6 + glow_blur*2) + cb*2 + 4
    if occ and V.z > occZ + 0.3 and dist((sx,sy), wall) + pad < wallR and dist((sx,sy), hole) - pad > holeR: cull
    if sx + pad < 0 or sx - pad > W or sy + pad < 0 or sy - pad > H: cull
    B = toCamera(cell.x, cell.y, cell.z + thickness)                  # ด้านหลัง
    item = {z: V.z, SX: sx, SY: sy, R: rp, blur: cb, opa: op, kind,
            BX, BY, BR = (B.z > near_clip) ? (W/2 + f*B.x/B.z, H/2 + f*B.y/B.z, f*cell.R/B.z) : BR = 0}

ลำดับ: ทุก cell ของทุก sheet (kind 0) ก่อน แล้วทุก cell ของทุก gate
```

### 8.4 คำสั่งวาด (draw commands)
```text
Blit { sprite, x, y (ศูนย์กลาง), S (scale), A (opacity 0..1), rows Y0..Y1 }
Line { x1, y1, x2, y2, HW (ครึ่งความกว้าง), สี premultiplied CR,CG,CB,CA (0..255) }
Disc { x, y, S (รัศมี), สี premultiplied CR,CG,CB,CA }

AddBlit: ข้ามถ้า sprite ไม่มี หรือ A <= 0 หรือ S <= 0
         half = ((spr.W - 1)/2 + 1) * S; ข้ามถ้าอยู่นอกเฟรมทั้งหมด
         Y0 = floor(y - half); Y1 = ceil(y + half)
AddLine: ข้ามถ้า alpha < 1; HW = width/2; Y0 = floor(min(y1,y2) - HW - 1); Y1 = ceil(max(y1,y2) + HW + 1)
AddDisc: ถ้า radius < 0.9: alpha *= radius/0.9; radius = 0.9   ข้ามถ้า alpha < 1
         Y0 = floor(y - radius - 1); Y1 = ceil(y + radius + 1)
สีของ line/disc:  CA = clamp(round(alpha), 0, 255); CR = r*CA div 255; CG = g*CA div 255; CB = b*CA div 255
```

---

## 9. Sprites: สูตรวาด, quantisation, cache

sprite = ภาพสี่เหลี่ยมจัตุรัส `W × W` พิกเซล (premultiplied alpha) ของหกเหลี่ยมหรือวงกลมรัศมี `rq` เบลอ `bq` วาดครั้งเดียวแล้วนำไปย่อ/ขยายด้วย bilinear ตอนวาดจริง

### 9.1 ชนิด (kind id ใช้ทุกที่ รวมถึงในไฟล์)
| id | ชื่อ | ใช้กับ |
|---|---|---|
| 0 | front | หน้าหกเหลี่ยม (เมื่อปิด glow) |
| 1 | back | ด้านหลังหกเหลี่ยม |
| 2 | glow | glow อย่างเดียว (เมื่อปิด front) |
| 3 | dust | bokeh dust |
| 4 | dot | bokeh dot |
| 5 | front_glow | หน้า + glow ในภาพเดียว (ใช้ปกติ) |
| 6 | gate | ผนังประตู |
| 7 | gate_edge | ขอบช่องประตู |
| 8 | gate_back | ด้านหลังผนังประตู |

### 9.2 สูตรวาด sprite (`BuildSpriteBase`)
ค่าทั้งหมดมาจาก settings (`hexagon_style.*`, `glow.*`, `bokeh_dust.*`)
```text
lw = max(1, rq * line_width)
g  = glow_strength * (glow_base + (1 - glow_base) * exp(-(bq / max(0.1, glow_falloff))²))
if kind == front_glow and 200*g < 6: kind = front           # glow มองไม่เห็นแล้ว ไม่ต้องขยายภาพ
if kind in {glow, front_glow}: gb = rq * glow_blur + bq;  m = gb*1.2 + lw*glow_width + 2
else:                          gb = bq;                    m = bq*1.2 + lw + 2
W = 2 * (ceil(rq) + ceil(m)) + 1;   c = (W - 1) / 2          # จุดศูนย์กลางอยู่กลางพิกเซล
canvas = W×W โปร่งใส (straight alpha)

if kind in {glow, front_glow}:                                # ชั้น glow
    stroke hexagon(c, c, rq), สี glow_colour alpha = 200*min(1, g) (0..255), ความกว้าง lw*glow_width
    if gb > 0.3: blur ทั้ง canvas รัศมี gb

if kind in {front, front_glow, back, dust, dot}:              # ชั้นหน้า (วาดบน canvas แยกแล้ววางทับ)
    face = W×W โปร่งใส
    front/front_glow:
        fill hexagon(c, c, rq) สี face_colour alpha face_alpha แล้ว stroke ขอบ rim_colour alpha rim_alpha กว้าง lw
        stroke hexagon(c, c, rq*inner_size) สี inner_rim_colour alpha rim_alpha*inner_alpha กว้าง lw*0.5
        line จากมุม 3 ไปมุม 4 ของ hexagon(c, c, rq) สี specular_colour alpha rim_alpha*specular_alpha กว้าง lw*0.6
    back:  stroke hexagon(c, c, rq) สี back_colour alpha rim_alpha*back_alpha กว้าง lw*0.8
    dust:  fill ellipse(c, c, rq, rq) สี dust_colour alpha 255
    dot:   fill ellipse(c, c, rq, rq) สี dot_colour alpha 255
    if bq > 0.3: blur face รัศมี bq
    วาง face ทับ canvas แบบ alpha blending ปกติ (source-over, straight alpha)

แปลงเป็น premultiplied: r' = r*a div 255 (เช่นเดียวกับ g, b), a' = a
```
**Gate variants** (`BuildSprite`): สร้างจากสูตรเดียวกันด้วย settings ที่แก้บางค่า
| kind | แก้ค่า | สร้างเป็น |
|---|---|---|
| gate | rim_colour = `game.gate_rim_colour`; face_alpha = `game.gate_face_alpha`; glow_base = 0.6 | front_glow |
| gate_edge | rim_colour = `game.gap_rim_colour`; glow_colour = `game.gap_glow_colour`; glow_strength ×1.6; face_alpha = `game.gate_face_alpha`; glow_base = 0.6 | front_glow |
| gate_back | back_colour = `game.gate_rim_colour`; back_alpha = 0.5 | back |

**รายละเอียดของ primitive (BGRABitmap)** ที่ต้องเลียนแบบ:
- `stroke` = `DrawPolygonAntialias`: เส้นปิดรอบรูป ความกว้าง `w` อยู่ **กึ่งกลางบนเส้นทาง** (ล้นเข้าและออกข้างละ w/2) รอยต่อมุมแบบ **bevel** ปลายเส้นแบบ **round** (ค่า default ของ BGRABitmap) และมี antialias
- `fill + stroke` (`DrawPolygonAntialias(points, c, w, fill)`): เติมรูปแล้ววาดขอบทับ
- `fill ellipse` = `FillEllipseAntialias`: วงกลมเต็ม antialias ตรงพิกัดทศนิยม
- `blur` = `FilterBlurRadial(radius, rbFast)`: การเบลอแบบกลมที่ประมาณ gaussian ถ้าพอร์ตแล้วใช้ **gaussian σ ≈ radius / 2** จะได้ใกล้เคียง (เป็นการประมาณ) ภาพจริงสำหรับเทียบคือ **atlas ในไฟล์** (หัวข้อ 16)

### 9.3 Quantisation (เลือก sprite จากขนาดและความเบลอ)
```text
lnS = ln(max(1.01, performance.size_step));   lnB = ln(max(1.05, performance.blur_step))
off = -floor(ln(0.5) / lnS)
GetSprite(kind, r, blur):
    r = max(r, 0.5)
    si = clamp(ceil(ln(r)/lnS - 1e-4) + off, 0, 255)          # bucket ที่ >= r: ย่อเล็กน้อย ไม่เคยขยาย
    bi = (blur < 0.5) ? 0 : clamp(1 + round(ln(blur/0.5) / lnB), 1, 63)
    rq = exp((si - off) * lnS)
    bq = (bi == 0) ? 0 : 0.5 * exp((bi - 1) * lnB)
    spr = cache[kind][si][bi] (สร้างถ้าไม่มี, 9.4–9.5)
    scale = r / spr.rq                                         # spr อาจเป็นของ bucket ข้างเคียง
```

### 9.4 Cache
- ตาราง `cache[9 kinds][256 sizes][64 blurs]` เก็บ sprite
- ถ้าขนาดรวม (W*W*4 ไบต์) เกิน `performance.cache_mb` MB ให้ล้างทั้งหมดตอนเริ่มเฟรม
- **โหมดซิงก์** (ส่งออกภาพ, reference frame): สร้าง sprite ทันทีเมื่อไม่มี

### 9.5 การสร้าง sprite เบื้องหลัง (โหมด live)
- มี thread สร้าง sprite **2 ตัว** (priority ต่ำ) กับคิวแบบ **LIFO** (ตัวใหม่สุดก่อน) จุได้สูงสุด 512 รายการ งานแต่ละชิ้นมีสำเนาของ settings ติดไปด้วย
- `generation` เพิ่มทุกครั้งที่ล้าง cache sprite ที่สร้างเสร็จแต่มาจาก generation เก่าจะถูกทิ้ง
- เมื่อ sprite ที่ต้องการยังไม่มี:
  1. ใส่คิว
  2. ยืม sprite ข้างเคียง: `d = 1..12` ลองตามลำดับ `(si+d, bi)`, `(si-d, bi)`, `(si, bi+d)`, `(si, bi-d)`, `(si+d, bi+d)`, `(si-d, bi-d)` (ตัวยืมถูกขยาย/ย่อด้วย `scale = r / borrowed.rq`)
  3. ถ้าไม่มีให้ยืม และ `rq + bq < 12` และยังอยู่ในงบเวลา (`sprite_budget_ms` นับจากต้นเฟรม) ให้สร้างทันที
  4. ไม่อย่างนั้นข้ามการวาดชิ้นนั้นในเฟรมนี้
- ต้นเฟรมรับ sprite ที่เสร็จแล้วเข้า cache (`CollectBuiltSprites`)

ผลคือเฟรมไม่ต้องรอ sprite ใหญ่ ๆ (บางตัวใช้เวลา 50 ms)

---

## 10. Screen layers: background และ vignette

สร้างตามขนาดเฟรม `W×H` แล้ว cache ไว้ **สูงสุด 4 ขนาด** (ถ้าเกินให้ทิ้งตัวที่ใช้นานที่สุด, LRU) ภาพไม่เคลื่อนตามกล้อง

```text
Background (ทึบ):
    fill base_colour (alpha 255)
    M = max(W, H)
    for i = 0..2:   (haze_1..3)
        radial gradient: สี haze_i_colour ที่จุดศูนย์กลาง → สีเดียวกัน alpha 0 ที่รัศมี
        centre = (W*haze_i_x, H*haze_i_y), radius = M*haze_i_radius
        วางทับ (alpha blending); gradient ถูกผสมแบบ gamma-corrected (ค่า default ของ BGRABitmap GradientFill)

Vignette (สีดำ มีเฉพาะ alpha):
    เริ่มโปร่งใส
    D = sqrt(W² + H²)
    radial gradient: ดำ alpha 0 ที่ centre (W*centre_x, H*centre_y) → ดำ alpha vignette.strength ที่รัศมี D*vignette.radius
    linear gradient: ดำ alpha shadow_alpha ที่ (0,0) → ดำ alpha 0 ที่ (W*shadow_end_x, H*shadow_end_y)
    ทั้งสองวางทับกันแบบ alpha blending
นอกรัศมีของ radial gradient ใช้สีปลาย (ค่าคงที่)
```
ไฟล์มีภาพทั้งสองขนาด 1280×720 (`screen_layers.*.png_base64`) ใช้ตรง ๆ ได้ (ยืดให้เต็มเฟรม)

---

## 11. Backend A — CPU rasterizer + OpenGL (HexGate Editor)

ระบบเดียวกับเกม HexGate ทุกพิกเซลคำนวณบน CPU แบบจำนวนเต็ม ผลลัพธ์จึง **กำหนดได้แน่นอน** (deterministic)

### 11.1 ขนาดเฟรม
```text
W = max(16, round(viewW * clamp(render_scale, 0.1, 2)));  H = ... viewH ...
```
เฟรมเล็กกว่าหน้าต่าง (render_scale 0.7 ใน HexGate) แล้ว OpenGL ยืดให้เต็มด้วย linear filtering

### 11.2 การแบ่งงานแบบขนาน
- thread = `performance.threads` (0 = จำนวน core ทั้งหมด) รวม main thread
- แบ่งเฟรมเป็น **tile ละ 16 แถว** แต่ละ thread ดึงเลข tile ถัดไปจากตัวนับร่วม (atomic increment) จนหมด
- ในแต่ละ tile:
  1. คัดลอกแถวของ background ลงเฟรม (ถ้า pass 0 ปิด: เติมดำ หรือลายหมากรุกก่อนเริ่ม)
  2. รันทุกคำสั่งใน draw list **ตามลำดับ** โดยข้ามคำสั่งที่ `Y1 < ty0` หรือ `Y0 > ty1` และตัดให้อยู่ในแถวของ tile
  3. ทำ vignette ของแถวเหล่านั้น
- tile ไม่ซ้อนกัน จึงไม่ต้องใช้ lock และลำดับการวาดยังถูกต้อง

### 11.3 การผสมพิกเซล (`BlendPx`) — premultiplied "over", จำนวนเต็ม
```c
void blend(px *p, int r, int g, int b, int a) {          // r,g,b,a premultiplied 0..255
    int ia = (255 - a) * 257;
    p->r = min(255, r + ((p->r * ia + 32768) >> 16));
    p->g = min(255, g + ((p->g * ia + 32768) >> 16));
    p->b = min(255, b + ((p->b * ia + 32768) >> 16));
    p->a = min(255, a + ((p->a * ia + 32768) >> 16));
}
```

### 11.4 Blit แบบ bilinear (`BlitTile`) — fixed point
พิกเซล `u` ของ sprite ไปตกที่จอ `x = X + (u - ctr) * S` (พิกัดดัชนีพิกเซล ไม่บวก 0.5)
```c
op  = clamp(round(A * 256), 0, 256);  if (op == 0) return;
ctr = (W - 1) / 2.0;  half = (ctr + 1) * S;
x0 = max(0, floor(X - half));  x1 = min(FW - 1, ceil(X + half));
y0 = max(ty0, max(0, Y0));     y1 = min(ty1, min(FH - 1, Y1));
inv = 1 / S;  duF = round(inv * 65536);
for y in y0..y1:
    v = (y - Y) * inv + ctr;  vi = floor(v);
    if (vi < -1 || vi >= W) continue;
    fv = round((v - vi) * 256);
    row0 = (vi >= 0) ? sprite row vi : none;   row1 = (vi + 1 < W) ? sprite row vi+1 : none;
    uF = round(((x0 - X) * inv + ctr) * 65536);
    for x in x0..x1:
        ui = uF >> 16 (arithmetic);  fu = (uF >> 8) & 255;  uF += duF;
        if (ui < -1 || ui >= W) continue;
        a00 = row0[ui], a10 = row0[ui+1], a01 = row1[ui], a11 = row1[ui+1]   // นอกขอบ = โปร่งใส (0,0,0,0)
        if all alpha == 0: continue
        w00 = (256-fu)*(256-fv); w10 = fu*(256-fv); w01 = (256-fu)*fv; w11 = fu*fv;
        sa = (a00.a*w00 + a10.a*w10 + a01.a*w01 + a11.a*w11) >> 16;   // เช่นเดียวกับ r, g, b
        blend(p, (sr*op) >> 8, (sg*op) >> 8, (sb*op) >> 8, (sa*op) >> 8);
```

### 11.5 เส้น (`LineTile`) และวงกลม (`DiscTile`)
```text
Line: x0 = max(0, floor(min(x1,x2) - HW - 1)); x1' = min(FW-1, ceil(max(x1,x2) + HW + 1)); y0/y1 ตามคำสั่งและ tile
      dx = x2-x1; dy = y2-y1; l2 = max(1e-6, dx²+dy²)
      ต่อพิกเซล: t = clamp(((x-x1)*dx + (y-y1)*dy)/l2, 0, 1); dist = |(x1 + t*dx, y1 + t*dy) - (x, y)|
                 fc = HW + 0.5 - dist; if fc > 0: cov = round(min(1, fc)*256); blend(p, CR*cov>>8, CG*cov>>8, CB*cov>>8, CA*cov>>8)
Disc: กรอบ x/y = ศูนย์กลาง ± (S + 1); fc = S + 0.5 - dist((x,y), centre); ที่เหลือเหมือนเส้น
```

### 11.6 Vignette บน CPU
vignette เป็นสีดำล้วน จึงแค่ทำให้มืดลงตาม alpha (ช่อง alpha ของเฟรมไม่เปลี่ยน):
```text
a = vig.alpha; if a > 0: ia = (255-a)*257; c = (c*ia + 32768) >> 16   สำหรับ r, g, b
```

### 11.7 การแสดงผลผ่าน OpenGL
```text
ครั้งแรก: glGenTextures; MIN/MAG = GL_LINEAR; WRAP = GL_CLAMP_TO_EDGE; UNPACK_ALIGNMENT = 4
          wglSwapIntervalEXT(1)    (vsync)
ทุกเฟรม: glViewport(0, 0, controlW, controlH)
          อัปโหลดเฟรม: ถ้าขนาดเปลี่ยน glTexImage2D(GL_RGBA8, W, H, GL_BGRA, GL_UNSIGNED_BYTE)
                       ไม่อย่างนั้น glTexSubImage2D (ลำดับไบต์ B,G,R,A จึงใช้ GL_BGRA ได้ตรง ๆ)
          ถ้า bitmap เก็บแถวบนลงล่าง: v0 = 1, v1 = 0 (กลับแกน v) ไม่อย่างนั้น v0 = 0, v1 = 1
          projection/modelview = identity; ปิด blend และ depth test; เปิด texture
          quad: (-1,-1)->(0,v0), (1,-1)->(1,v0), (1,1)->(1,v1), (-1,1)->(0,v1)
          SwapBuffers (รอ vblank); glFinish (ไม่ให้ driver เข้าคิวเฟรมล่วงหน้า)
ถ้า OpenGL ใช้ไม่ได้: วาดด้วย GDI (stretch) และจำกัดเฟรมที่ 60 fps ด้วยตัวจับเวลา
```
loop: `Application.OnIdle` เรียกเฟรมถัดไปทันที (`Done := False`) จังหวะเวลามาจาก vsync ของ SwapBuffers ระหว่าง frame UI ของ LCL (เมนู, slider) ยังทำงานได้ (`timeBeginPeriod(1)` ทำให้ `Sleep(1)` แม่นยำ)

---

## 12. Backend B — SDL3 GPU (HexGate Simulator)

engine ยังสร้าง draw list บน CPU (ใช้ `BuildFrame` เหมือนเดิม) แต่ GPU ทำการผสมพิกเซลทั้งหมด

### 12.1 การตั้งค่า
- หน้าต่าง `SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY`, renderer เริ่มต้นของ SDL, `SDL_SetRenderVSync(renderer, 1)`
- texture ทุกใบใช้ `SDL_PIXELFORMAT_ARGB8888` (ตรงกับ B,G,R,A ในหน่วยความจำบน little-endian) และ `SDL_SCALEMODE_LINEAR`
- พิกัดวาดทั้งหมดเป็นพิกัดเฟรม (`FW×FH` = render size) แล้วใช้ `SDL_SetRenderScale(outW/FW, outH/FH)` ให้ GPU ยืดภาพ

### 12.2 Blend modes
| สิ่งที่วาด | blend |
|---|---|
| background | `NONE` (คัดลอก) |
| sprites, disc, atlas | `BLEND_PREMULTIPLIED` : `out = src + dst*(1 - src.a)` |
| line (geometry) | `BLEND` (straight alpha) |
| vignette, HUD | `BLEND` (straight alpha) |

### 12.3 Blit
```text
texture ของ sprite: สร้างครั้งแรกที่ใช้ (W×W, premultiplied) ผูกกับ sprite แล้วลบเมื่อ engine ลบ sprite (SpriteFreeHook)
o = clamp(A, 0, 1)
colorMod = (o, o, o); alphaMod = o           # premultiplied: สีต้องจางตาม alpha ด้วย
size = spr.W * S
dst = (X + 0.5 - size/2, Y + 0.5 - size/2, size, size)      # +0.5 ให้ texel centre ตรงกับ CPU blitter
```

### 12.4 Line และ Disc
```text
Line: ถ้า CA <= 0 หรือความยาว < 0.01: ข้าม
      n = (-dy, dx)/len * max(0.5, HW)
      quad 4 จุด: (x1,y1)+n, (x2,y2)+n, (x2,y2)-n, (x1,y1)-n   (ทุกจุด +0.5)
      สี straight = (CR/CA, CG/CA, CB/CA), alpha = CA/255; วาดด้วย SDL_RenderGeometry (ไม่มี antialias)
Disc: texture วงกลมขาว 64×64 premultiplied, alpha = clamp(32 - 0.5 - dist(texel centre, (32,32)), 0, 1)
      colorMod = (CR/255, CG/255, CB/255), alphaMod = CA/255
      size = (S + 0.5) * 2 * 64/63;  dst = (X + 0.5 - size/2, Y + 0.5 - size/2, size, size)
```
ลำดับ: background → ทุกคำสั่งตามลำดับ → vignette → (HUD/ข้อความ)

### 12.5 ATLAS mode (ใช้แค่ภาพในไฟล์ ไม่ต้องมีสูตร sprite)
draw list เหมือนเดิม แต่แทนที่ sprite ด้วยภาพจาก atlas และใช้ background/vignette จากไฟล์
```text
โหลด atlas PNG (straight alpha) แล้วแปลงเป็น premultiplied: c = c * a div 255
สร้างตาราง lookup[kind][sizeLevel][blurLevel] -> entry  (จับคู่ entry.rq/bq กับ level ที่ใกล้ที่สุด)

FindSprite(kind, R, blur):         # R = spr.rq * S (รัศมีบนจอ), blur = spr.bq * S
    si = level แรกที่ size_levels[si] >= R (ถ้าไม่มี ใช้ตัวสุดท้าย)
    blur' = blur * size_levels[si] / max(0.5, R)                 # ความเบลอที่ขนาดของ level นั้น
    bi = blur level ที่ใกล้ blur' ที่สุด
    return lookup[kind][si][bi]  (ไม่มี = ไม่วาด)

วาด: src = (e.x, e.y, e.w, e.w);  size = e.w * R / e.rq;  dst = (X + 0.5 - size/2, Y + 0.5 - size/2, size, size)
     colorMod = (o,o,o), alphaMod = o
```
atlas มีแค่ 9 ขนาด × 5 ระดับเบลอ ภาพจึงต่างจาก RECIPE mode เล็กน้อย (ความเบลอเปลี่ยนเป็นขั้น)

---

## 13. การจำลองการบิน (autopilot) และ game loop

ทั้ง Editor และ Simulator ใช้โค้ดเดียวกัน (ค่ากติกามาจาก `game.*` ในไฟล์ แก้ได้ในกลุ่ม "Game rules (autopilot)")

### 13.1 สถานะ
`gates[]` (z, gx, gy, gr), `P = (px, py)` (ตำแหน่งยาน = กล้อง), `Vel = (vx, vy)`, `speed`, `lastGateZ`, `lastGX`, `lastGY`, `level` (0..80, ปุ่ม ±5), `passed`, `hits`, `steering`, `mouse` ใน [-1, 1]

### 13.2 `ResetFlight()`
```text
gates = []; engine.ClearGates()
lastGateZ = cam.z + 20; lastGX = px; lastGY = py; speed = start_speed
```

### 13.3 `SpawnGates()`
```text
lim = corridor_radius - 1.5
while lastGateZ < cam.z + far_clip + 6:
    spacing = max(min_spacing, start_spacing - spacing_per_gate * level)
    gr      = max(min_gap, start_gap - gap_per_gate * level)
    spd     = max(0.5, min(max_speed, start_speed + speed_per_gate * level))
    maxShift = lateral_speed * spacing / spd * 0.7
    tries = 0
    repeat:
        a = random*2pi; rr = sqrt(random) * max(0, lim)
        gx = rr*cos(a); gy = rr*sin(a); d = dist((gx,gy), (lastGX,lastGY)); tries += 1
    until d <= maxShift or tries > 30
    if d > maxShift and d > 0: (gx, gy) = last + ((gx,gy) - last) * maxShift / d
    lastGateZ += max(1, spacing); lastGX = gx; lastGY = gy
    gates.append(lastGateZ, gx, gy, gr); engine.AddGate(lastGateZ, gx, gy, gr)
```
(ในเกมจริง ช่องและความเร็วยังคูณ/บวกด้วยค่าของระดับความยาก ดูภาคผนวก C.2–C.3)

### 13.4 `Fly(dt)` ต่อเฟรม
```text
if paused: engine.Animate(0); return
lim = max(0, corridor_radius - 1.5)
g = ประตูแรกที่ z > cam.z (หรือไม่มี)
target = steering ? (mx*lim, my*lim) : (g ? (g.gx, g.gy) : (0, 0))
old = P
เคลื่อน P เข้าหา target ไม่เกิน lateral_speed*dt ต่อเฟรม
ถ้า |P| > lim: P = P * lim/|P|
if dt > 0: Vel += ((P - old)/dt - Vel) * min(1, dt*8)
speed += (min(max_speed, start_speed + speed_per_gate*level) - speed) * min(1, dt*2)
engine.settings.camera.speed = speed            # autopilot ควบคุมความเร็วกล้อง
if gates on: SpawnGates()
z0 = cam.z; z1 = z0 + speed*dt
สำหรับประตูที่ z0 < gate.z <= z1: ผ่าน (passed+1) ถ้า dist(P, gate.g) <= gate.gr - player_radius ไม่อย่างนั้นชน (hits+1)
ลบประตูหน้าสุดที่ z < z0 - 2
engine.SetManualCamera(px, py, yaw = vx*0.012, pitch = -vy*0.008, roll = -vx*0.02)
engine.focusOverride = g ? max(2, g.z - z0) : 12
engine.Animate(dt)
```
**สำคัญเมื่อบันทึกไฟล์:** autopilot เขียนทับ `camera.speed` ของ engine ทุกเฟรม ก่อนบันทึกต้องใส่ค่า `camera.speed` ของไฟล์กลับไปชั่วคราว (โปรแกรมทั้งสองทำแล้ว) ในแผงแก้ไข แถว Camera → Speed แก้ค่าของไฟล์ ไม่ใช่ความเร็วที่ autopilot ใช้

### 13.5 ลำดับต่อเฟรมของโปรแกรม
```text
t = now (ms); dt = min(0.1, (t - lastTick)/1000); lastTick = t
if pendingFx and now - lastEdit > 150 ms: engine.Invalidate(pendingFx); pendingFx = {}
Fly(dt)
BuildFrame/Render ที่ render size
present (vsync)
```

---

## 14. รูปแบบไฟล์ hexgate-graphics v1

JSON (UTF-8) ไฟล์เดียว ภาพทุกภาพเป็น PNG เข้ารหัส base64 ขนาดประมาณ 5.4 MB ตัวเลขทศนิยมเขียนแบบสั้น (9 หลักสำคัญ เช่น `1.1`)

### 14.1 Top level
| key | ชนิด | ความหมาย |
|---|---|---|
| `format` | string | ต้องเป็น `"hexgate-graphics"` |
| `version` | int | `1` |
| `generator` | string | โปรแกรมที่เขียน (`HexGate graphics export`, `HexGate SDL3 graphics export`, `HexGate Editor (edited)`, `HexGate Simulator (edited)`) |
| `created` | string | `yyyy-mm-ddThh:nn:ss` (เวลาท้องถิ่น) |
| `readme` | string[] | คำอธิบายย่อ |
| `conventions` | object | `world`, `screen`, `colors`, `angles` (หัวข้อ 1) |
| `seed` | int | seed ของโลก |
| `settings` | object | ค่าตั้งทุกค่า (14.2) |
| `game` | object | กติกาเกม ตารางความยาก/คุณภาพ HUD (ภาคผนวก C) |
| `camera`, `world`, `draw` | object | สูตรเป็นข้อความ (สรุปของหัวข้อ 4–8) |
| `sprites` | object | สูตร sprite, quantisation, atlas (14.3) |
| `screen_layers` | object | background, vignette (PNG 1280×720), disc (14.4) |
| `reference_frame` | object | เฟรมอ้างอิง 1280×720 (14.5) |

### 14.2 `settings.<group>.<name>`
```json
"camera.speed": {
  "group": "Camera", "name": "Speed", "kind": "float",
  "value": 9, "min": -10, "max": 20, "decimals": 2,
  "hint": "Forward speed, world units per second ...",
  "rebuilds": []
}
"hexagon_style.rim_colour": { "group": "Hexagon style", "name": "Rim colour", "kind": "color",
  "value": [195, 215, 250, 255], ... "rebuilds": ["sprites"] }
```
- key สร้างด้วย `GfxKey(group, name)`: ตัวพิมพ์เล็ก เก็บเฉพาะ `a-z 0-9` กลุ่มของตัวอื่นทั้งหมดกลายเป็น `_` ตัวเดียว (ไม่ขึ้นต้นด้วย `_`) แล้วต่อด้วย `.`
  - ตัวอย่าง: `("Depth of field", "Focus distance")` → `depth_of_field.focus_distance`
- `rebuilds` ใช้ชื่อ `sprites`, `screen_layers`, `world`, `dust`, `sparks` (หัวข้อ 2.1)
- **กติกาความเข้ากันได้:** key ที่ไม่รู้จักให้ข้าม key ที่ไม่มีให้ใช้ค่า default ของ engine สีที่มีแค่ 3 ค่าให้ alpha = 255 ค่าสีถูก clamp 0..255

### 14.3 `sprites`
- `pixels`, `canvas[]`, `kinds[]` (`id`, `name`, `recipe[]`), `quantisation[]` = ข้อความ (หัวข้อ 9)
- `atlas`:
  - `size_levels` = `[2, 3.2, 5.12, 8.19, 13.1, 21, 33.6, 53.7, 86]` (px)
  - `blur_levels` = `[0, 1.5, 4, 10, 25]` (px)
  - `width` = 4096, `height` (≈1413)
  - `entries[]` = `{kind, kind_name, rq, bq, x, y, w, h}` มี 9 kinds × 9 × 5 = **405** รายการ แต่ละรายการเป็นสี่เหลี่ยมจัตุรัส `w = h` จุดศูนย์กลาง `((w-1)/2, (h-1)/2)`
  - `png_base64` = atlas PNG แบบ **straight alpha**
- วิธีสร้าง atlas (ใช้ซ้ำได้):
  1. bake ทุก (kind, size, blur) ด้วยสูตร 9.2
  2. เรียงจาก W มากไปน้อย
  3. shelf packing กว้าง 4096 ช่องว่าง 1 px: ถ้าใส่ต่อในชั้นไม่ได้ให้ขึ้นชั้นใหม่ที่ `y += shelfH + 1`
  4. แปลง premultiplied → straight: `c = min(255, c*255 div a)` (a = 0 → พิกเซลโปร่งใส)
- หมายเหตุ: `front_glow` ที่ระดับเบลอสูง อาจเป็นภาพ `front` ธรรมดาจากกฎ `200*g < 6` (หัวข้อ 9.2) แต่ยังมี kind เป็น front_glow ใน entry

### 14.4 `screen_layers`
- `background.recipe[]` และ `vignette.recipe[]` เป็นข้อความ, `width` = 1280, `height` = 720, `png_base64`
  - background: ทึบ
  - vignette: ดำ + alpha
- `disc`: `{recipe, size: 64}` = texture วงกลมของ sparks (หัวข้อ 12.4)

### 14.5 `reference_frame`
`{note, time, seed, camera_position: [x, y, z], focus_distance, width: 1280, height: 720, png_base64}`
- เฟรมที่ CPU renderer วาด (ไม่มี HUD) หลังให้ autopilot บิน 6 วินาที (360 เฟรม × 1/60 s)
- sprite ทุกตัวถูกสร้างแบบซิงก์ จึงเป็นคุณภาพเต็ม

### 14.6 การบันทึก (Editor/Simulator)
- เขียนทับ: `settings`, `sprites` (bake atlas ใหม่), `screen_layers`, `reference_frame`, ตัวเลข `game.*` 11 ค่า (7 หลักสำคัญ), `seed`, `generator`, `created`
- ส่วนอื่น (`readme`, `conventions`, `camera`, `world`, `draw`, `game.rules`, `hud` ฯลฯ) **คงไว้เหมือนเดิม**
- ค่า `game.*` ที่ autopilot ใช้: `player_radius`, `lateral_speed`, `start_speed`, `max_speed`, `speed_per_gate`, `start_gap`, `min_gap`, `gap_per_gate`, `start_spacing`, `min_spacing`, `spacing_per_gate`

### 14.7 การสร้างไฟล์
- เกม HexGate / HexGate SDL3: กด **F9** หรือรัน `HexGate.exe --export-graphics [file.json]` (ไม่เปิดหน้าต่าง)
- HexGate Editor: ถ้าไม่มีไฟล์ จะเริ่มจากค่า default ของ engine แล้ว **Save As** สร้างไฟล์ที่ครบถ้วน (มี settings/sprites/screen_layers/reference_frame/game numbers แต่ไม่มีข้อความ readme/camera/world/draw/hud)

---

## 15. พฤติกรรมของโปรแกรมแก้ไข (Editor / Simulator)

| เรื่อง | HexGate Editor (LCL) | HexGate Simulator (SDL3) |
|---|---|---|
| เมนู File | Open (Ctrl+O), Save (Ctrl+S), Save As (Ctrl+Shift+S), Exit (Alt+F4) — TMainMenu ของ Windows | Open/Save/Save As/Exit วาดเอง (Esc = Exit) — dialog ของ SDL3 (`SDL_ShowOpenFileDialog`, callback อาจมาจาก thread อื่น ส่งผ่านตัวแปรที่มี lock) |
| ถามก่อนทิ้งการแก้ไข | Save / Don't Save / Cancel (`QuestionDlg`) | Save / Don't Save / Cancel (`SDL_ShowMessageBox`) |
| แผงแก้ไข | dropdown กลุ่ม + แถวละ slider (0..1000 ขั้น) + ช่องตัวเลข / ปุ่มสี + alpha | แผงวาดเอง กว้าง 430 px แถวละ 26 px แก้ด้วยการลาก ล้อเมาส์ ลูกศร (Shift ×10) |
| ค่าสี | ปุ่มเลือกสี (RGB) + ช่อง alpha | แยก 4 แถว R, G, B, A |
| ค่าที่แก้ได้ | 121 ค่าตั้ง + 11 ค่า Game rules | เหมือนกัน |
| หลังแก้ | ค่าเปลี่ยนทันที, invalidate หลังหยุดแก้ 150 ms, ชื่อไฟล์มี `*` | เหมือนกัน |
| โหมดภาพ | RECIPE (engine วาดเอง) | RECIPE หรือ ATLAS (ปุ่ม A) |
| ดูภาพในไฟล์ | แท็บ Images (atlas, background, vignette, reference frame) + แท็บ File (สรุปเนื้อหา) | — |
| ปุ่มจำลอง | F5 pause, F6 gates, F7/F8 level, F9 restart, Ctrl+R reload | Space, G, −/+, R |

---

## 16. การตรวจสอบผลการพอร์ต และข้อจำกัดที่ทราบ

**สิ่งที่เทียบได้แบบตรงตัว (ควรเหมือนทุกบิต):**
- `hashf`, `noise`, RNG: พิมพ์ค่า 1,000 ค่าแรกเทียบกับต้นฉบับ
- จำนวนและตำแหน่ง cell ของ sheet `k` ใด ๆ ที่ seed 2026
- atlas: bake sprite ด้วยสูตรของคุณที่ `(kind, rq, bq)` ของแต่ละ entry แล้วเทียบกับภาพใน atlas ความต่างที่ยอมรับได้มาจาก antialias และ blur ของ BGRABitmap (เทียบด้วยค่าเฉลี่ยความต่างต่อพิกเซล ไม่ใช่เทียบทุกบิต)

**เทียบเฟรมกับ `reference_frame`:**
- reference frame บอก `time`, `seed`, `camera_position`, `focus_distance` แต่ **ไม่มี yaw/pitch/roll และตำแหน่งอนุภาค/ประตู** (ประตูมาจาก `Random` ธรรมดา)
- จึงเทียบได้ในเชิงภาพรวม: สี ความสว่าง ความหนาแน่น ขนาดหกเหลี่ยม ความเบลอ ไม่ใช่เทียบทีละพิกเซล
- ถ้าต้องการเทียบแบบตรงตัว ให้ตั้ง `SetManualCamera(camera_position.x, camera_position.y, 0, 0, 0)`, `cam.z = camera_position.z`, focus = `focus_distance`, ปิดประตูและอนุภาคทั้งสองฝั่ง แล้วเรนเดอร์จากต้นฉบับเพิ่มเอง

**ความต่างที่ทราบระหว่าง backend:**
| เรื่อง | CPU (A) | GPU (B) |
|---|---|---|
| เส้นขอบด้านข้าง | antialias (ระยะถึงเส้น + 0.5) | quad ไม่มี antialias (ความกว้างขั้นต่ำ 1 px) |
| bilinear | fixed point 8 บิต | ฮาร์ดแวร์ (float) |
| จุดศูนย์กลางพิกเซล | พิกัดจำนวนเต็ม | +0.5 (ชดเชยให้ตรงกัน) |
| vignette | คูณ (255-a)/255 ต่อช่อง | alpha blending ดำ (ผลเท่ากัน) |
| ยืดภาพเฟรม | OpenGL linear | SDL render scale linear |

**ข้อจำกัดอื่น:**
- ความเบลอใช้ `FilterBlurRadial(rbFast)` ของ BGRABitmap ซึ่งไม่ใช่ gaussian แท้ ภาษาอื่นต้องประมาณ (หัวข้อ 9.2)
- การเรียง item ใช้ quicksort ที่ไม่ stable ลำดับของ item ที่ z เท่ากันอาจต่างกันได้ (มองไม่เห็นความต่าง)
- โหมด live อาจวาด sprite ข้างเคียงไปก่อน 1–2 เฟรม (หัวข้อ 9.5)

---

## 17. ประสิทธิภาพที่วัดได้

เครื่องทดสอบ: CPU 12 threads, จอ 60 Hz

| โปรแกรม | ขนาดเฟรม | build list | วาด | fps |
|---|---|---|---|---|
| HexGate Editor (CPU 12 threads + OpenGL) | 682×558 (render scale 0.7) | 0.5–0.8 ms | 4–8 ms | 60 (vsync) |
| HexGate Simulator (SDL3 GPU) | ~900×500 | 0.6–0.9 ms | GPU 0.6–1.5 ms, 1,900–6,400 draw calls | 60 (vsync) |
| HexGate SDL3 HIGH | full | — | ~4 ms ต่อเฟรม | 60 |

ส่วนที่ช้าที่สุดของการวาดบน CPU คือการผสมพิกเซลของ sprite ใหญ่ที่เบลอมาก ถ้าพอร์ตไป GPU ส่วนนี้แทบไม่มีต้นทุน งานที่เหลือบน CPU คือ CollectItems + sort (~1 ms)

---

## ภาคผนวก A — ค่าตั้งทั้ง 121 ค่า

- คอลัมน์ "HexGate file value" = ค่าใน `hexgate_graphics.json` ที่ export จากเกม HexGate
- คอลัมน์ "engine default" = `DefaultHexSettings` ใน `uhexbackground.pas` (ใช้เมื่อไฟล์ไม่มี key นั้น)
- สีไม่มี min/max (ทุกช่อง 0..255)

| # | key (`settings.<key>`) | engine field | kind | HexGate file value | engine default | min | max | dec | rebuilds | meaning |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `camera.speed` | `Speed` | float | 9 | 2.0 | -10 | 20 | 2 | live | Forward speed, world units per second (hex radius = 1 unit by default). |
| 2 | `camera.sway_x` | `SwayX` | float | 0.6 | 0.6 | 0 | 5 | 2 | live | Side-to-side drift amplitude, units. |
| 3 | `camera.sway_y` | `SwayY` | float | 0.4 | 0.4 | 0 | 5 | 2 | live | Up-down drift amplitude, units. |
| 4 | `camera.sway_freq` | `SwayFreq` | float | 0.05 | 0.05 | 0 | 0.5 | 3 | live | Sway cycles per second. |
| 5 | `camera.roll` | `RollAmp` | float | 1.5 | 1.5 | 0 | 20 | 1 | live | Camera roll amplitude, degrees. |
| 6 | `camera.look_freq` | `LookFreq` | float | 0.03 | 0.03 | 0 | 0.3 | 3 | live | Speed of the automatic look-around and roll, cycles per second. |
| 7 | `camera.mouse_smooth` | `MouseSmooth` | float | 2 | 2 | 0.1 | 10 | 1 | live | How fast the camera follows the mouse (1/s). |
| 8 | `camera.near_clip` | `NearClip` | float | 0.5 | 0.5 | 0.05 | 5 | 2 | live | Nothing closer than this is drawn, units. |
| 9 | `camera.field_of_view` | `Fov` | float | 55 | 55 | 10 | 120 | 0 | world, dust, sparks | Vertical field of view, degrees. |
| 10 | `camera.far_clip` | `FarClip` | float | 42 | 42 | 5 | 150 | 0 | world, dust, sparks | View distance, units. Larger = more hexagons to draw. |
| 11 | `camera.look_yaw` | `LookYaw` | float | 4 | 3 | 0 | 30 | 1 | world, dust, sparks | Automatic look-around left/right, degrees. |
| 12 | `camera.look_pitch` | `LookPitch` | float | 3 | 2 | 0 | 30 | 1 | world, dust, sparks | Automatic look-around up/down, degrees. |
| 13 | `camera.mouse_steer` | `MouseSteer` | float | 8 | 8 | 0 | 40 | 1 | world, dust, sparks | How far the mouse turns the camera, degrees. |
| 14 | `depth_of_field.focus_distance` | `FocusDist` | float | 12 | 12 | 0.5 | 60 | 1 | live | Distance of the sharp plane, units. |
| 15 | `depth_of_field.focus_pull` | `FocusPullAmp` | float | 0 | 3 | 0 | 30 | 1 | live | Automatic focus drift amplitude, units. |
| 16 | `depth_of_field.focus_pull_freq` | `FocusPullFreq` | float | 0.04 | 0.04 | 0 | 0.5 | 3 | live | Focus drift cycles per second. |
| 17 | `depth_of_field.aperture` | `Aperture` | float | 0.9 | 1.0 | 0 | 5 | 2 | live | Blur strength. CoC px = Aperture x H / 100 x \|z - focus\| / z. |
| 18 | `depth_of_field.max_blur` | `MaxBlur` | float | 40 | 40 | 0 | 150 | 0 | live | Largest blur radius, px per 1000 px of output height. |
| 19 | `fog.fog_start` | `FogStart` | float | 22 | 22 | 0 | 150 | 1 | live | Distance where hexagons start to fade, units. |
| 20 | `fog.fog_end` | `FogEnd` | float | 42 | 42 | 0 | 150 | 1 | live | Distance where they are gone, units. |
| 21 | `fog.near_fade_start` | `NearFadeStart` | float | 7 | 7 | 0 | 20 | 2 | live | Hexagons closer than this start to fade out, units. |
| 22 | `fog.near_fade_end` | `NearFadeEnd` | float | 3.5 | 3.5 | 0 | 20 | 2 | live | Hexagons closer than this are invisible, units. |
| 23 | `hexagon_field.hex_radius` | `HexRadius` | float | 1 | 1 | 0.2 | 5 | 2 | world | Hexagon size, world units. |
| 24 | `hexagon_field.cell_gap` | `Gap` | float | 1.1 | 1.10 | 0.9 | 3 | 2 | world | Lattice spacing / hex size. 1 = touching. |
| 25 | `hexagon_field.sheet_gap` | `SheetGap` | float | 3.5 | 3.5 | 0.5 | 20 | 2 | world | Distance between honeycomb sheets along the flight path, units. |
| 26 | `hexagon_field.z_jitter` | `ZJitter` | float | 0.35 | 0.35 | 0 | 2 | 2 | world | Random depth offset of each cell, x sheet gap. |
| 27 | `hexagon_field.thickness` | `Thickness` | float | 0.3 | 0.30 | 0 | 3 | 2 | world | Prism depth (front to back face), units. |
| 28 | `hexagon_field.size_jitter` | `SizeJitter` | float | 0.1 | 0.10 | 0 | 0.6 | 2 | world | Random size variation. |
| 29 | `hexagon_field.layout_distance` | `LayoutDist` | float | 12 | 12 | 1 | 60 | 1 | world | Distance at which the diagonal mask matches the screen, units. |
| 30 | `hexagon_field.edge_slope` | `EdgeSlope` | float | 0.45 | 0.45 | -2 | 2 | 2 | world | Slope of the empty-area edge (screen heights per screen height). |
| 31 | `hexagon_field.edge_offset` | `EdgeOffset` | float | -20 | 0.05 | -1 | 1 | 2 | world | Moves the edge down (+) or up (-), screen heights. |
| 32 | `hexagon_field.fade_start` | `FadeStart` | float | -1 | -0.05 | -1 | 1 | 2 | world | Distance from the edge where cells start (negative = into the empty side). |
| 33 | `hexagon_field.fade_end` | `FadeEnd` | float | 0.25 | 0.25 | -1 | 2 | 2 | world | Distance from the edge where the field is full. |
| 34 | `hexagon_field.density` | `Density` | float | 0.35 | 0.60 | 0 | 1 | 2 | world | Chance a cell inside the field holds a hexagon. |
| 35 | `hexagon_field.noise_scale` | `NoiseScale` | float | 0.08 | 0.08 | 0.005 | 1 | 3 | world | Cluster noise frequency per unit. |
| 36 | `hexagon_field.cluster_low` | `ClusterLo` | float | 0.35 | 0.35 | 0 | 1 | 2 | world | Noise value where clusters start. |
| 37 | `hexagon_field.cluster_high` | `ClusterHi` | float | 0.65 | 0.65 | 0 | 1 | 2 | world | Noise value where clusters are full. |
| 38 | `hexagon_field.cluster_min` | `ClusterMin` | float | 0.1 | 0.10 | 0 | 1 | 2 | world | Density kept between clusters. |
| 39 | `hexagon_field.loose_chance` | `LooseChance` | float | 0 | 0.06 | 0 | 0.5 | 3 | world | Chance an empty cell near the edge spawns a stray hexagon. |
| 40 | `hexagon_field.loose_zone` | `LooseZone` | float | 0.3 | 0.30 | 0 | 1 | 2 | world | Width of the zone where strays appear (screen heights). |
| 41 | `hexagon_field.loose_drift` | `LooseDrift` | float | 1.5 | 1.5 | 0 | 6 | 2 | world | How far strays drift into the empty side (x hex radius). |
| 42 | `hexagon_field.loose_shrink` | `LooseShrink` | float | 0.4 | 0.40 | 0 | 0.9 | 2 | world | Max size reduction of strays. |
| 43 | `hexagon_style.rim_colour` | `EdgeColor` | color | [195, 215, 250, 255] | [195, 215, 250, 255] |  |  |  | sprites | Front face outline. |
| 44 | `hexagon_style.face_colour` | `FillColor` | color | [8, 14, 30, 255] | [8, 14, 30, 255] |  |  |  | sprites | Front face fill. |
| 45 | `hexagon_style.back_colour` | `BackColor` | color | [110, 140, 195, 255] | [110, 140, 195, 255] |  |  |  | sprites | Back face and side edges. |
| 46 | `hexagon_style.inner_rim_colour` | `InnerColor` | color | [140, 170, 225, 255] | [140, 170, 225, 255] |  |  |  | sprites | Thin inner outline. |
| 47 | `hexagon_style.specular_colour` | `SpecColor` | color | [235, 245, 255, 255] | [235, 245, 255, 255] |  |  |  | sprites | Highlight on the upper-left edge. |
| 48 | `hexagon_style.line_width` | `LineWidth` | float | 0.055 | 0.055 | 0.01 | 0.3 | 3 | sprites | Rim width x on-screen hex radius (min 1 px). |
| 49 | `hexagon_style.rim_alpha` | `RimAlpha` | float | 230 | 230 | 0 | 255 | 0 | sprites | 0..255 |
| 50 | `hexagon_style.face_alpha` | `FillAlpha` | float | 175 | 175 | 0 | 255 | 0 | sprites | 0..255 - how much the face hides what is behind it. |
| 51 | `hexagon_style.back_alpha` | `BackAlpha` | float | 0.3 | 0.30 | 0 | 1 | 2 | sprites | Back face alpha x rim alpha. |
| 52 | `hexagon_style.inner_size` | `InnerSize` | float | 0.86 | 0.86 | 0.3 | 1 | 2 | sprites | Inner rim size relative to the face. |
| 53 | `hexagon_style.inner_alpha` | `InnerAlpha` | float | 0.22 | 0.22 | 0 | 1 | 2 | sprites | Inner rim alpha x rim alpha. |
| 54 | `hexagon_style.specular_alpha` | `SpecAlpha` | float | 0.6 | 0.60 | 0 | 1 | 2 | sprites | Highlight alpha x rim alpha. |
| 55 | `hexagon_style.side_alpha` | `SideAlpha` | float | 0.25 | 0.25 | 0 | 1 | 2 | live | Side edges alpha x rim alpha. |
| 56 | `hexagon_style.side_max_blur` | `SideMaxBlur` | float | 3 | 3 | 0 | 50 | 1 | live | Side edges are drawn only below this blur (px per 1000 px height). |
| 57 | `glow.glow_colour` | `GlowColor` | color | [70, 110, 190, 255] | [70, 110, 190, 255] |  |  |  | sprites | Halo colour. |
| 58 | `glow.glow_width` | `GlowWidth` | float | 2.5 | 2.5 | 0.5 | 10 | 1 | sprites | Halo stroke width x rim width. |
| 59 | `glow.glow_blur` | `GlowBlur` | float | 0.22 | 0.22 | 0 | 1.5 | 2 | sprites | Halo blur radius x on-screen hex radius. |
| 60 | `glow.glow_strength` | `GlowStrength` | float | 0.6 | 0.6 | 0 | 2 | 2 | sprites | Overall halo opacity. |
| 61 | `glow.glow_base` | `GlowBase` | float | 0.1 | 0.10 | 0 | 1 | 2 | sprites | Glow kept on blurred (out of focus) hexagons, 0..1. |
| 62 | `glow.glow_falloff` | `GlowRange` | float | 4 | 4 | 0.5 | 40 | 1 | sprites | Blur radius (px) at which the glow has mostly faded: sharp = in focus = glowing. |
| 63 | `background.base_colour` | `BaseColor` | color | [5, 8, 18, 255] | [5, 8, 18, 255] |  |  |  | screen_layers | Background fill. |
| 64 | `background.haze_1_colour` | `HazeColor[0]` | color | [36, 54, 90, 255] | [36, 54, 90, 255] |  |  |  | screen_layers | Radial haze colour; alpha = strength. |
| 65 | `background.haze_1_x` | `HazeX[0]` | float | 0.28 | 0.28 | -0.5 | 1.5 | 2 | screen_layers | Haze centre X (0..1). |
| 66 | `background.haze_1_y` | `HazeY[0]` | float | 0.7 | 0.70 | -0.5 | 1.5 | 2 | screen_layers | Haze centre Y (0..1). |
| 67 | `background.haze_1_radius` | `HazeR[0]` | float | 0.7 | 0.70 | 0.05 | 2 | 2 | screen_layers | Haze radius x the longer image side. |
| 68 | `background.haze_2_colour` | `HazeColor[1]` | color | [45, 66, 110, 210] | [45, 66, 110, 210] |  |  |  | screen_layers | Radial haze colour; alpha = strength. |
| 69 | `background.haze_2_x` | `HazeX[1]` | float | 0.65 | 0.65 | -0.5 | 1.5 | 2 | screen_layers | Haze centre X (0..1). |
| 70 | `background.haze_2_y` | `HazeY[1]` | float | 0.95 | 0.95 | -0.5 | 1.5 | 2 | screen_layers | Haze centre Y (0..1). |
| 71 | `background.haze_2_radius` | `HazeR[1]` | float | 0.55 | 0.55 | 0.05 | 2 | 2 | screen_layers | Haze radius x the longer image side. |
| 72 | `background.haze_3_colour` | `HazeColor[2]` | color | [32, 48, 82, 200] | [32, 48, 82, 200] |  |  |  | screen_layers | Radial haze colour; alpha = strength. |
| 73 | `background.haze_3_x` | `HazeX[2]` | float | 0.95 | 0.95 | -0.5 | 1.5 | 2 | screen_layers | Haze centre X (0..1). |
| 74 | `background.haze_3_y` | `HazeY[2]` | float | 0.1 | 0.10 | -0.5 | 1.5 | 2 | screen_layers | Haze centre Y (0..1). |
| 75 | `background.haze_3_radius` | `HazeR[2]` | float | 0.4 | 0.40 | 0.05 | 2 | 2 | screen_layers | Haze radius x the longer image side. |
| 76 | `bokeh_dust.count` | `DustCount` | float | 70 | 90 | 0 | 600 | 0 | dust | Number of dust particles behind the focus plane. |
| 77 | `bokeh_dust.size_min` | `DustSizeMin` | float | 0.3 | 0.3 | 0.01 | 5 | 2 | dust | World units. |
| 78 | `bokeh_dust.size_max` | `DustSizeMax` | float | 1.2 | 1.2 | 0.01 | 5 | 2 | dust | World units. |
| 79 | `bokeh_dust.alpha_min` | `DustAlphaMin` | float | 15 | 15 | 0 | 255 | 0 | dust | 0..255 |
| 80 | `bokeh_dust.alpha_max` | `DustAlphaMax` | float | 55 | 55 | 0 | 255 | 0 | dust | 0..255 |
| 81 | `bokeh_dust.dot_chance` | `DustDotChance` | float | 0.3 | 0.3 | 0 | 1 | 2 | dust | Share of small bright dots. |
| 82 | `bokeh_dust.dot_size` | `DustDotSize` | float | 0.15 | 0.15 | 0.02 | 1 | 2 | dust | Dot size x dust size. |
| 83 | `bokeh_dust.dust_colour` | `DustColor` | color | [100, 130, 180, 255] | [100, 130, 180, 255] |  |  |  | sprites | Big soft blobs. |
| 84 | `bokeh_dust.dot_colour` | `DustDotColor` | color | [170, 200, 240, 255] | [170, 200, 240, 255] |  |  |  | sprites | Small bright dots. |
| 85 | `bokeh_dust.min_blur` | `DustMinBlur` | float | 6 | 6 | 0 | 60 | 1 | live | Dust is always at least this blurred (px per 1000 px height). |
| 86 | `sparks.count` | `SparkCount` | float | 450 | 450 | 0 | 2000 | 0 | sparks | Number of embers. |
| 87 | `sparks.field_bias` | `SparkFieldBias` | float | 0 | 0.9 | 0 | 1 | 2 | sparks | 0 = anywhere, 1 = only inside the hexagon field. |
| 88 | `sparks.size_min` | `SparkSizeMin` | float | 0.012 | 0.012 | 0.002 | 0.5 | 3 | sparks | World units. |
| 89 | `sparks.size_max` | `SparkSizeMax` | float | 0.035 | 0.035 | 0.002 | 0.5 | 3 | sparks | World units. |
| 90 | `sparks.alpha_min` | `SparkAlphaMin` | float | 120 | 120 | 0 | 255 | 0 | sparks | 0..255 |
| 91 | `sparks.alpha_max` | `SparkAlphaMax` | float | 255 | 255 | 0 | 255 | 0 | sparks | 0..255 |
| 92 | `sparks.rise_min` | `SparkRiseMin` | float | 0.3 | 0.3 | -5 | 10 | 2 | sparks | Upward speed, units/s. |
| 93 | `sparks.rise_max` | `SparkRiseMax` | float | 1.2 | 1.2 | -5 | 10 | 2 | sparks | Upward speed, units/s. |
| 94 | `sparks.life_min` | `SparkLifeMin` | float | 3 | 3 | 0.2 | 30 | 1 | sparks | Seconds. |
| 95 | `sparks.life_max` | `SparkLifeMax` | float | 9 | 9 | 0.2 | 30 | 1 | sparks | Seconds. |
| 96 | `sparks.twinkle_min` | `SparkTwinkleMin` | float | 2 | 2 | 0 | 30 | 1 | sparks | Twinkle speed, rad/s. |
| 97 | `sparks.twinkle_max` | `SparkTwinkleMax` | float | 8 | 8 | 0 | 30 | 1 | sparks | Twinkle speed, rad/s. |
| 98 | `sparks.sway` | `SparkSway` | float | 0.3 | 0.3 | 0 | 5 | 2 | live | Sideways sway, units/s. |
| 99 | `sparks.twinkle_depth` | `SparkTwinkleDepth` | float | 0.4 | 0.40 | 0 | 1 | 2 | live | 0 = steady, 1 = blinks fully off. |
| 100 | `sparks.halo_size` | `SparkHaloSize` | float | 3 | 3 | 1 | 10 | 1 | live | Halo radius x core radius. |
| 101 | `sparks.halo_alpha` | `SparkHaloAlpha` | float | 0.18 | 0.18 | 0 | 1 | 2 | live | Halo alpha x spark alpha. |
| 102 | `sparks.core_colour` | `SparkCoreColor` | color | [255, 196, 110, 255] | [255, 196, 110, 255] |  |  |  | live | Bright centre. |
| 103 | `sparks.halo_colour` | `SparkHaloColor` | color | [255, 130, 30, 255] | [255, 130, 30, 255] |  |  |  | live | Glow around the centre. |
| 104 | `vignette.strength` | `VigAlpha` | float | 160 | 160 | 0 | 255 | 0 | screen_layers | Corner darkness alpha (0..255). |
| 105 | `vignette.centre_x` | `VigX` | float | 0.5 | 0.50 | 0 | 1 | 2 | screen_layers | 0..1 |
| 106 | `vignette.centre_y` | `VigY` | float | 0.55 | 0.55 | 0 | 1 | 2 | screen_layers | 0..1 |
| 107 | `vignette.radius` | `VigRadius` | float | 0.62 | 0.62 | 0.1 | 2 | 2 | screen_layers | x image diagonal. |
| 108 | `vignette.shadow_alpha` | `ShadowAlpha` | float | 130 | 130 | 0 | 255 | 0 | screen_layers | Top-left shadow alpha (0..255). |
| 109 | `vignette.shadow_end_x` | `ShadowX` | float | 0.45 | 0.45 | 0.01 | 1.5 | 2 | screen_layers | Where the shadow fades out (0..1). |
| 110 | `vignette.shadow_end_y` | `ShadowY` | float | 0.4 | 0.40 | 0.01 | 1.5 | 2 | screen_layers | Where the shadow fades out (0..1). |
| 111 | `game.corridor_radius` | `CorridorRadius` | float | 10 | 0 | 0 | 30 | 1 | world | No ambient hexagons closer than this to the flight path, units (0 = off). |
| 112 | `game.gate_face_alpha` | `GateFillAlpha` | float | 215 | 215 | 0 | 255 | 0 | sprites | How solid the gate walls look (0..255). |
| 113 | `game.gate_rim_colour` | `GateRimColor` | color | [130, 215, 255, 255] | [130, 215, 255, 255] |  |  |  | sprites | Rim of the gate wall hexagons. |
| 114 | `game.gap_rim_colour` | `GateEdgeColor` | color | [255, 200, 110, 255] | [255, 200, 110, 255] |  |  |  | sprites | Rim of the hexagons around the gap. |
| 115 | `game.gap_glow_colour` | `GateEdgeGlow` | color | [255, 140, 40, 255] | [255, 140, 40, 255] |  |  |  | sprites | Glow of the hexagons around the gap. |
| 116 | `performance.render_scale` | `RenderScale` | float | 0.7 | 0.7 | 0.25 | 1 | 2 | live | Internal resolution x window size (frame is stretched to fit). |
| 117 | `performance.cache_mb` | `CacheMB` | float | 384 | 384 | 32 | 2048 | 0 | live | Sprite cache limit; the cache is emptied when it is exceeded. |
| 118 | `performance.threads` | `Threads` | float | 0 | 0 | 0 | 64 | 0 | live | Drawing threads. 0 = one per logical CPU. |
| 119 | `performance.sprite_budget_ms` | `SpriteBudget` | float | 4 | 4 | 0 | 20 | 1 | live | Live view: time per frame allowed for making small sprites on the spot. Big sprites are always made by background threads; meanwhile the nearest cached sprite is scaled in, so no frame stalls. |
| 120 | `performance.size_step` | `SizeStep` | float | 1.08 | 1.08 | 1.01 | 1.5 | 3 | sprites | Sprite size buckets grow by this factor. Sprites are drawn at their exact size, so this only trades memory for sharpness. |
| 121 | `performance.blur_step` | `BlurStep` | float | 1.12 | 1.12 | 1.03 | 2 | 2 | sprites | Sprite blur buckets grow by this factor. Smaller = smoother focus changes, more sprites. |

---

## ภาคผนวก B — โครงสร้างข้อมูลภายใน engine

```text
Cell        { x, y, z, R: float; loose: bool }
Sheet       { k: int; cells: Cell[] }
Gate        { z, gx, gy, gr, ext: float; cells: Cell[]; kinds: byte[] (1 = wall, 2 = gap rim) }
Particle    { pos: vec3; size, alpha, life, lifeSpeed, phase, twinkle, rise: float; dot: bool }
DrawItem    { z, SX, SY, R, blur, opa, BX, BY, BR: float; kind: byte (0 ambient, 1 gate wall, 2 gap rim) }
Sprite      { W: int; rq: float; bq: float; kind: int; pix: W*W premultiplied BGRA }
DrawCmd     { kind: blit|line|disc; pass: int; Y0, Y1: int;
              sprite; X, Y, S, A, X2, Y2, HW: float; CR, CG, CB, CA: int (premultiplied) }
ScreenCache { W, H; base (opaque), vig (black + alpha); stamp (LRU) }   x4
SpriteCache sprites[9][256][64], pending[9][256][64]
FrameStats  { sheets, cells, visible, culled, spritesMade, borrowed, threads, commands, frameMs, setupMs, drawMs, queued, skipped }
```
API ของ engine ที่โปรแกรมใช้: `ResetDefaults`, `SetSeed`, `SetMouse`, `AddGate`, `ClearGates`, `SetManualCamera`, `FocusOverride`, `Invalidate`, `Animate(dt)`, `Render(dest, W, H, passes, checkers, stats)` (CPU), `BuildFrame(W, H, passes, stats)` + `Cmd(i)/CmdCount/FrameBase/FrameVignette/JobBase/JobVig/ScreenGen` (GPU), `BakeSprite(kind, rq, bq)`, `Params` (รายการค่าตั้ง: group, name, hint, kind, pointer, min, max, decimals, effects), `Settings`, `Seed`, `Time`, `CameraPos`, `FocusNow`, `Stats`, `AsyncSprites`

---

## ภาคผนวก C — ข้อมูลเกม (game.*)

### C.1 Numbers (`game.*`)

| key | value |
|---|---|
| `player_radius` | 0.3 |
| `lateral_speed` | 11 |
| `start_speed` | 9 |
| `max_speed` | 26 |
| `speed_per_gate` | 0.25 |
| `start_gap` | 3 |
| `min_gap` | 1.5 |
| `gap_per_gate` | 0.05 |
| `start_spacing` | 28 |
| `min_spacing` | 18 |
| `spacing_per_gate` | 0.35 |
| `boost_factor` | 1.5 |
| `boost_drain_per_s` | 0.4 |
| `boost_refill_per_s` | 0.12 |
| `perfect_fraction` | 0.35 |

`game.units`: world units: hexagon radius = 1 (setting hexagon_field.hex_radius); speeds in units/s

### C.2 Rules (`game.rules`, verbatim)

```text
level = gates spawned in this run (0 in the menu / autopilot)
spacing = max(min_spacing, start_spacing - spacing_per_gate * level)
gap radius = max(1.2, max(min_gap, start_gap - gap_per_gate * level) + difficulty.gap_add)
speed = min(max_speed, start_speed + speed_per_gate * gates_passed) * difficulty.speed_mul (x boost_factor while boosting)
speed eases toward its target: speed += (target - speed) * min(1, dt * 2)
gap centre: random point in the disc of radius corridor_radius - 1.5, at most max_shift from the previous gap,
  max_shift = lateral_speed * spacing / (speed_at_level * difficulty.speed_mul * boost_factor) * 0.7
the first gate of a run is at camera z + 20 + spacing; gates are kept spawned up to camera z + far_clip + 6
passing: distance(ship, gap centre) <= gap radius - player_radius; perfect when < gap radius * perfect_fraction
points: 1 + perfect streak (if perfect), x2 while boosting; a crash costs a life and gives 1 s of protection
ship steering: towards the mouse target (mouse -1..1 * (corridor_radius - 1.5)) or by keys, at lateral_speed;
  clamped to the disc of radius corridor_radius - 1.5
camera = ship: SetManualCamera(x + shake, y + shake, yaw = vx * 0.012, pitch = -vy * 0.008, roll = -vx * 0.02),
  v = smoothed ship velocity (v += (dp/dt - v) * min(1, dt * 8)); shake = (random - 0.5) * shake_amount * 1.2,
  shake_amount = 1 after a crash, -1.5 per second
focus distance = max(2, distance to the next gate), 12 when there is none
```

### C.3 Difficulties (`game.difficulties`)

| name | gap_add | speed_mul | lives |
|---|---|---|---|
| EASY | 0.699999988 | 0.850000024 | 5 |
| NORMAL | 0 | 1 | 3 |
| HARD | -0.400000006 | 1.14999998 | 2 |

### C.4 Graphics quality (`game.graphics_quality`)

| name | render_scale |
|---|---|
| LOW | 0.5 |
| MEDIUM | 0.600000024 |
| HIGH | 0.699999988 |
| ULTRA | 0.850000024 |

### C.5 Look overrides (`game.look_overrides`)

the game changes these engine settings at start (already included in "settings")

| key | value |
|---|---|
| `hexagon_field.corridor_radius` | 10 |
| `hexagon_field.edge_offset` | -20 |
| `hexagon_field.fade_start` | -1 |
| `hexagon_field.density` | 0.35 |
| `hexagon_field.loose_chance` | 0 |
| `depth_of_field.focus_pull` | 0 |
| `depth_of_field.aperture` | 0.9 |
| `camera.look_yaw` | 4 |
| `camera.look_pitch` | 3 |
| `sparks.field_bias` | 0 |
| `bokeh_dust.count` | 70 |

### C.6 HUD (`game.hud`)

u = frame height / 100; x, y in pixels of the frame (render size); text y = top of the text

Font: family = Segoe UI, weight = bold, files = segoeuib.ttf, seguisb.ttf, arialbd.ttf, size_note = text sizes are line heights in pixels (BGRABitmap FontHeight; SDL3_ttf point size = the same number), shadow = black, alpha 180, offset max(1, round(size * 0.06)) px right and down, opacity = blinking / fading text is drawn with a copy opacity, blink = 0.55 + 0.45 * sin(time * 5)

| palette key | [r, g, b, a] |
|---|---|
| `white` | [255, 255, 255, 255] |
| `gold` | [255, 200, 110, 255] |
| `soft` | [170, 190, 220, 255] |
| `title_blue` | [130, 215, 255, 255] |
| `red` | [255, 90, 80, 255] |
| `crash_flash` | [255, 30, 30, 120] |
| `crosshair_far` | [255, 255, 255, 190] |
| `crosshair_in_gap` | [120, 255, 150, 255] |
| `crosshair_outside` | [255, 90, 80, 255] |
| `life_full_rim` | [130, 215, 255, 255] |
| `life_full_fill` | [60, 120, 190, 200] |
| `life_lost` | [120, 130, 150, 140] |
| `boost_bar` | [110, 200, 255, 255] |
| `boost_bar_boosting` | [255, 170, 70, 255] |
| `menu_band` | [4, 8, 18, 140] |
| `menu_row_selected` | [255, 200, 110, 45] |
| `pause_dim` | [0, 0, 0, 120] |
| `game_over_dim` | [0, 0, 0, 100] |

Elements (verbatim):

- crash flash: full frame, crash_flash colour with alpha 120 * flash (flash 1 -> 0 at 1.8 per second)
- gap ring: ellipse around the projected next gap centre, radius = gap radius * pixels per unit, gold with alpha 70 + 110 * (1 - min(1, distance / 40)), width max(1.5, u * 0.25); only while the gate is more than 1.5 units ahead
- crosshair (frame centre): circle radius r = u * 1.6, width u * 0.3, four ticks from r * 1.3 to r * 2.3; colour crosshair_far when the next gate is 15+ units away, else in_gap / outside; flickers (alpha / 3) during protection
- SCORE n: (u*3, u*2), white, size u*6, left
- BEST n: (u*3, u*9), soft, size u*3.4, left; PERFECT xN (streak > 1): (u*3, u*13.5), gold, size u*3.4
- lives: hexagons radius u*2.2 at (W - u*4.5 - i*u*5.5, u*5.5), full: rim life_full_rim width u*0.35 filled life_full_fill; lost: life_lost width u*0.3
- SPEED n (speed * 10): (u*3, H - u*8), soft, size u*3.4, left
- boost bar: width W*0.24 centred, top H - u*5, height u*1.4, outline white alpha 120 width u*0.2, fill inset u*0.3 by energy (boost_bar / boost_bar_boosting); label BOOST [SPACE] centred at y = bar top - u*4, size u*2.6
- message (GO!, PERFECT +n, CRASH!): centred at y = H/2 - u*18, size u*7, alpha 255 * min(1, time_left * 2), 1.2 s
- menu: dark band (W/2 +- u*42, H/2 - u*40 .. H/2 + u*44) menu_band; HEXGATE title centred at H/2 - u*38, size u*14, title_blue
- main menu: subtitle at H/2 - u*20 size u*3.4 soft; items PLAY / OPTIONS / EXIT at H/2 - u*8 + i*u*11; selected: gold size u*6.5 between hexagons radius u*1.6 at x = W/2 +- u*17 (fill gold alpha 90*blink); others white alpha 200 size u*5.5; best line at H/2 + u*30; help at H - u*7 size u*2.5
- options: header OPTIONS at H/2 - u*22 size u*5.5; rows at H/2 - u*12 + i*u*7 (BACK + u*2), label at W/2 - u*34 size u*3.8, value right-aligned at W/2 + u*34; selected row band menu_row_selected; volume = 10 hexagons over u*26 ending u*7 before the value
- pause: pause_dim over the frame, PAUSED size u*10 at H/2 - u*10, hint at H/2 + u*4 size u*4
- game over: game_over_dim, GAME OVER size u*12 red at H/2 - u*22, SCORE size u*7 at H/2 - u*6, best / NEW BEST! at H/2 + u*3, hint at H/2 + u*13
- FPS (option): bottom right, size u*2.8 at H - u*5, detail line size u*2.2 at H - u*8.5

---

## ภาคผนวก D — แผนที่ไฟล์ซอร์ส

| ไฟล์ | อยู่ใน | หน้าที่ |
|---|---|---|
| `uhexbackground.pas` | HexGate, HexGate SDL3, HexGate Editor, HexGate Simulator (ตัวเดียวกัน) | engine: ค่าตั้ง, โลก, กล้อง, อนุภาค, sprite, draw list, CPU rasterizer |
| `ueditmain.pas` | HexGate Editor | หน้าต่าง, เมนู, แผงแก้ไข, OpenGL output, autopilot |
| `ugfxfile.pas` | HexGate Editor | อ่าน/เขียนไฟล์, ถอดภาพ, สรุปไฟล์ |
| `ugfxbake.pas` / `usimexport.pas` / `ugfxexport.pas` | Editor / Simulator / เกม | สร้าง settings, atlas, screen layers, reference frame เป็น JSON |
| `ugpuout.pas` | HexGate SDL3, HexGate Simulator | GPU backend (SDL3) + ATLAS mode |
| `usimdata.pas` | HexGate Simulator | อ่าน/เขียนไฟล์, atlas lookup (FindSprite) |
| `usimui.pas` | HexGate Simulator | เมนูและแผงแก้ไขที่วาดเอง (SDL3_ttf) |
| `HexGateSim.lpr` | HexGate Simulator | loop หลัก, dialog, autopilot |
| `ugategame.pas` | เกม | กติกาเกม, เมนู, HUD, `SpecJSON` (ส่วน `game` ของไฟล์) |
| `hexgate_graphics.json` | HexGate, HexGate Editor, HexGate Simulator | ข้อมูลกราฟิกที่ export แล้ว |
