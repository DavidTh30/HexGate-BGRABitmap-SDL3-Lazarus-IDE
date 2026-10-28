unit USimExport;

{ Simulator copy of HexGate's graphics export (ugfxexport.pas): the parts
  that rebuild a file's settings, sprite atlas, screen layers and reference
  frame from the engine, used by "Save" so an edited file stays consistent.

  Original description:
  Exports everything HexGate draws into one self-contained JSON file
  ("hexgate-graphics" format, version 1):

    settings        every engine value (current, min, max, hint), key = "group.name"
    game            game rules, difficulty / quality tables, HUD layout and colours
    camera, world   the formulas and algorithms (hash, noise, sheets, gates,
                    particles, projection, depth of field, fog, occlusion)
    sprites         drawing recipe of every sprite kind, the size / blur
                    quantisation, and a baked atlas (PNG, straight alpha)
    screen_layers   background and vignette recipes + baked 1280x720 images
    draw            frame order, blend modes and the exact blit mapping
    reference_frame one frame rendered by the CPU renderer, with its camera state

  Images are PNG files encoded as base64 strings, so the file can be read by
  any program with a JSON parser and a PNG decoder. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, fpjson, base64, BGRABitmap, BGRABitmapTypes,
  UHexBackground;

const
  GfxAtlasSizes: array[0..8] of single = (2, 3.2, 5.12, 8.19, 13.1, 21, 33.6, 53.7, 86);
  GfxAtlasBlurs: array[0..4] of single = (0, 1.5, 4, 10, 25);

// numbers are written as 1.1 instead of 1.10000000000000E+000 (call before parsing)
procedure UseNiceFloats;
function SettingsJSON(Hex: THexBackground): TJSONObject;
function SpritesJSON(Hex: THexBackground; out AtlasInfo: TJSONObject): TJSONObject;
function ScreenLayersJSON(Hex: THexBackground): TJSONObject;
function ReferenceFrameJSON(Hex: THexBackground): TJSONObject;

implementation

type
  // numbers as 1.1 instead of 1.10000000000000E+000
  TNiceFloat = class(TJSONFloatNumber)
  protected
    function GetAsString: TJSONStringType; override;
  end;

function TNiceFloat.GetAsString: TJSONStringType;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := FloatToStrF(AsFloat, ffGeneral, 9, 0, FS);
end;

function GfxKey(const Group, Name: string): string;

  function Part(const S: string): string;
  var
    c: char;
    Sep: boolean;
  begin
    Result := '';
    Sep := False;
    for c in LowerCase(S) do
      if c in ['a'..'z', '0'..'9'] then
      begin
        if Sep and (Result <> '') then Result := Result + '_';
        Result := Result + c;
        Sep := False;
      end
      else
        Sep := True;
  end;

begin
  Result := Part(Group) + '.' + Part(Name);
end;

// short decimal of a single (avoids 1.10000002384186)
function F(v: single): double;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := StrToFloat(FloatToStrF(v, ffGeneral, 7, 0, FS), FS);
end;

function PngBase64(Bmp: TBGRABitmap): string;
var
  M: TMemoryStream;
  S: string;
begin
  M := TMemoryStream.Create;
  try
    Bmp.SaveToStreamAsPng(M);
    SetLength(S, M.Size);
    if M.Size > 0 then Move(M.Memory^, S[1], M.Size);
    Result := EncodeStringBase64(S);
  finally
    M.Free;
  end;
end;

function Lines(const A: array of string): TJSONArray;
var
  S: string;
begin
  Result := TJSONArray.Create;
  for S in A do Result.Add(S);
end;

{ ------------------------------------------------------------- settings }

function SettingsJSON(Hex: THexBackground): TJSONObject;
var
  i: integer;
  O: TJSONObject;
  Fx: TJSONArray;
  P: TParamInfo;
begin
  Result := TJSONObject.Create;
  for i := 0 to High(Hex.Params) do
  begin
    P := Hex.Params[i];
    O := TJSONObject.Create;
    O.Add('group', P.Group);
    O.Add('name', P.Name);
    if P.Kind = pkColor then
    begin
      O.Add('kind', 'color');
      O.Add('value', TJSONArray.Create([P.PColor^.red, P.PColor^.green, P.PColor^.blue, P.PColor^.alpha]));
    end
    else
    begin
      O.Add('kind', 'float');
      O.Add('value', F(P.PValue^));
      O.Add('min', F(P.Min));
      O.Add('max', F(P.Max));
      O.Add('decimals', P.Decimals);
    end;
    O.Add('hint', P.Hint);
    Fx := TJSONArray.Create;
    if ivSprites in P.Effects then Fx.Add('sprites');
    if ivScreen in P.Effects then Fx.Add('screen_layers');
    if ivField in P.Effects then Fx.Add('world');
    if ivDust in P.Effects then Fx.Add('dust');
    if ivSparks in P.Effects then Fx.Add('sparks');
    O.Add('rebuilds', Fx);           // empty = read every frame
    Result.Add(GfxKey(P.Group, P.Name), O);
  end;
end;

{ ---------------------------------------------------------- algorithms }

function CameraJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('axes', 'world and camera space: x right, y down, z forward (into the screen); units: hexagon radius = hexagon_field.hex_radius');
  Result.Add('rotation', Lines([
    'd = p - camera_position',
    'yaw (look right > 0):   x1 = d.x*cos(yaw) - d.z*sin(yaw);  z1 = d.x*sin(yaw) + d.z*cos(yaw)',
    'pitch (look up > 0):    y2 = d.y*cos(pitch) + z1*sin(pitch); z2 = -d.y*sin(pitch) + z1*cos(pitch)',
    'roll:                   xc = x1*cos(roll) - y2*sin(roll);   yc = x1*sin(roll) + y2*cos(roll);  zc = z2']));
  Result.Add('projection', Lines([
    'f = (H / 2) / tan(camera.field_of_view / 2)      (H = frame height in pixels)',
    'screen x = W/2 + f * xc / zc,  screen y = H/2 + f * yc / zc,  radius in pixels = f * R / zc',
    'nothing closer than camera.near_clip is drawn']));
  Result.Add('motion_free_flight', Lines([
    'w = 2*pi*time; camera z += camera.speed * dt',
    'x = camera.sway_x * sin(w * camera.sway_freq);  y = camera.sway_y * sin(w * camera.sway_freq * 0.73 + 1.3)',
    'yaw = rad(camera.look_yaw) * sin(w * camera.look_freq) + steer_yaw',
    'pitch = rad(camera.look_pitch) * sin(w * camera.look_freq * 0.81 + 0.7) + steer_pitch',
    'roll = rad(camera.roll) * sin(w * camera.look_freq * 0.57 + 2.1)',
    'mouse steer: steer_yaw += (mouse_x * rad(camera.mouse_steer) - steer_yaw) * min(1, dt * camera.mouse_smooth);',
    '  steer_pitch += (-mouse_y * rad(camera.mouse_steer) * 0.6 - steer_pitch) * min(1, dt * camera.mouse_smooth)']));
  Result.Add('motion_game', 'see game.rules: the game sets x, y, yaw, pitch, roll and the focus distance itself');
  Result.Add('depth_of_field', Lines([
    'focus = max(0.3, depth_of_field.focus_distance + depth_of_field.focus_pull * sin(w * depth_of_field.focus_pull_freq)) (or the game''s focus)',
    'blur radius px (circle of confusion) = min(depth_of_field.max_blur * H / 1000, depth_of_field.aperture * H / 100 * |zc - focus| / zc)']));
  Result.Add('fade', Lines([
    'smoothstep(e0, e1, x) = t*t*(3-2t), t = clamp((x - e0) / (e1 - e0), 0, 1)',
    'fade(z) = (1 - smoothstep(fog.fog_start, fog.fog_end, z)) * smoothstep(fog.near_fade_end, fog.near_fade_start, z)',
    'gate walls use near fade 5.0 -> 2.2 instead of the fog settings; anything with fade < 0.02 is skipped']));
end;

function WorldJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('hash', Lines([
    'hashf(a, b, c, d) -> 0..1, all integer maths on unsigned 32 bit with wrap-around:',
    'h = a*73856093 xor b*19349663 xor c*83492791 xor d*2654435761',
    'h = h xor (h >> 16); h = h * 0x7FEB352D; h = h xor (h >> 15); h = h * 0x846CA68B; h = h xor (h >> 16)',
    'result = h / 4294967296']));
  Result.Add('value_noise', Lines([
    'noise(x, y, z, seed): xi = floor(x) ...; f = fractional part, smoothed f*f*(3-2f) per axis',
    'trilinear blend of hashf(xi+dx, yi+dy, zi+dz, seed) for dx, dy, dz in {0, 1}',
    'cluster(x, y, z) = 0.65 * noise(x*s, y*s, z*s, seed) + 0.35 * noise(x*s*2.1 + 17, y*s*2.1 + 5, z*s*2.1, seed + 1),  s = hexagon_field.noise_scale']));
  Result.Add('mask', Lines([
    's = 2 * hexagon_field.layout_distance * tan(camera.field_of_view / 2)',
    't(x, y) = y / s - (hexagon_field.edge_offset - hexagon_field.edge_slope * x / s)   (> 0: inside the field)']));
  Result.Add('sheets', Lines([
    'honeycomb sheets every hexagon_field.sheet_gap along z; sheet k is at z0 = k * sheet_gap',
    'kept in range: k from floor((cam_z + near_clip - thickness - z_jitter * sheet_gap) / sheet_gap) to ceil((cam_z + far_clip) / sheet_gap)',
    'r = hex_radius; dx = 1.5 * r * cell_gap; dy = sqrt(3) * r * cell_gap; flat-top hexagons',
    'offset ox = hashf(k, 11, 0, seed) * dx, oy = hashf(k, 12, 0, seed) * dy',
    'extent: Ex = far_clip * (tan(fov/2) * 2 + tan(rad(min(80, look_yaw + mouse_steer)))) + sway_x + 2r;',
    '        Ey = far_clip * (tan(fov/2) * 1.05 + tan(rad(min(80, look_pitch + mouse_steer * 0.6)))) + sway_y + 2r',
    'cells: col from floor((-Ex - ox) / dx) to ceil((Ex - ox) / dx), row from floor((-Ey - oy) / dy) - 1 to ceil((Ey - oy) / dy)',
    'x = ox + col * dx; y = oy + row * dy (+ dy/2 when col is odd); h[i] = hashf(col, row, k, seed * 8 + i), i = 0..6',
    'skip when corridor_radius > 0 and x^2 + y^2 < corridor_radius^2',
    'p = smoothstep(fade_start, fade_end, t) * density * (cluster_min + (1 - cluster_min) * smoothstep(cluster_low, cluster_high, cluster(x, y, z0)))',
    'kept when h0 < p; otherwise a loose (stray) cell when -loose_zone < t < 0.05 and h1 < loose_chance; else skipped',
    'z = z0 + (h2 - 0.5) * z_jitter * sheet_gap;  R = r * (1 - size_jitter * 0.7 + h3 * size_jitter)',
    'loose cells: d = r * (0.5 + h4 * loose_drift); x -= d * 0.6; y -= d * 0.8; R *= 1 - loose_shrink * h5; z += (h6 - 0.5) * sheet_gap * 0.5']));
  Result.Add('gates', Lines([
    'a gate = honeycomb disc at depth Z with a round gap (centre GX, GY, radius GR); lattice as the sheets but without offset',
    'cells with x^2 + y^2 > (corridor_radius + 4r)^2 are outside the disc; cells with distance to the gap centre < GR + 0.85r form the gap',
    'cell radius 0.96r; cells closer than GR + 2.4r to the gap centre are the gap rim (sprite gate_edge), the rest gate',
    'gates are removed once the camera is 2 units past them']));
  Result.Add('dust', Lines([
    'count = bokeh_dust.count; spawned in front of the camera at zr in [focus_distance * 1.2, far_clip] (respawn: [0.8, 1] * far_clip)',
    'x = cam_x + (rand*2 - 1) * tan(fov/2) * 1.8 * zr; y = cam_y + (rand*2 - 1) * tan(fov/2) * zr;',
    'accepted when rand < 0.25 + 0.75 * exp(-(t(x, y) / 0.3)^2) (30 tries)',
    'dot = rand < dot_chance; size = rand(size_min, size_max) (x dot_size for dots); alpha = rand(alpha_min, alpha_max) (x 2.5 for dots, max 255)',
    'respawn when zr < focus_distance * 0.8 or zr > far_clip * 1.05',
    'drawn: alpha = alpha/255 * fade(z) * smoothstep(focus_distance*0.8, focus_distance*1.3, z); radius = f * size / z;',
    '  blur = max(circle of confusion, min_blur * H / 1000); sprite dust or dot']));
  Result.Add('sparks', Lines([
    'count = sparks.count; zr in [max(near_fade_start, focus_distance * 0.4), focus_distance * 2.5], x/y as dust;',
    '  accepted when rand < (1 - field_bias) + field_bias * smoothstep(fade_start - 0.05, fade_end + 0.1, t)',
    'size = rand(size_min, size_max); alpha = rand(alpha_min, alpha_max); phase = rand*2pi; twinkle = rand(twinkle_min, twinkle_max);',
    '  rise = rand(rise_min, rise_max); life speed = 1 / max(0.1, rand(life_min, life_max)); life starts random (0 on respawn)',
    'update: life += dt * life_speed; y -= rise * dt; x += cos(time * 0.7 + phase) * sway * dt; respawn when life >= 1, zr < near_clip*2 or zr > far_clip',
    'drawn: a = alpha * sin(pi * life) * fade(z) * ((1 - twinkle_depth) + twinkle_depth * sin(time * twinkle + phase)); skip when a < 3',
    '  rp = max(0.3, f * size / z); blur = circle of confusion',
    '  blur > 2 rp: one disc radius blur, halo colour, alpha max(a * 0.05, a * (2rp / blur)^2 * 0.4)',
    '  else: disc radius rp * halo_size, halo colour, alpha a * halo_alpha; then disc radius rp, core colour, alpha a',
    'disc: radius < 0.9 -> alpha *= radius / 0.9, radius = 0.9; coverage = clamp(radius + 0.5 - distance, 0, 1)']));
  Result.Add('random', 'world cells and gate hashing are deterministic from the seed; particles and gap positions use ordinary random numbers');
end;

function DrawJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('order', Lines([
    '1 background (screen_layers.background, copied)',
    '2 bokeh dust (sprites dust / dot)',
    '3 hexagons of all sheets and gates, sorted far to near; for each: back face, side edges, front face',
    '4 sparks (discs)',
    '5 vignette (screen_layers.vignette)',
    '6 HUD (game.hud)']));
  Result.Add('hexagon_item', Lines([
    'front: centre and radius r projected from the cell; back: the same cell moved hexagon_field.thickness further in z, radius BR',
    'back face (when BR > 0.3): sprite back (gate_back for gates) at the back position',
    'side edges (BR > 0.3, r > 5 and blur < hexagon_style.side_max_blur * H / 1000): 6 lines from front corner i to back corner i,',
    '  corner = centre + radius * (cos(i*60deg), sin(i*60deg)); width max(1, r * line_width * 0.7); colour back_colour,',
    '  alpha rim_alpha * side_alpha * opacity',
    'front face: sprite front_glow (front when the glow pass is off; gate / gate_edge for gate cells), opacity = fade(z)']));
  Result.Add('occlusion', Lines([
    'the nearest gate that is between 5.5 units and fog_start away hides hexagons behind it (z > gate z + 0.3) whose',
    'whole sprite lies inside the projected disc (radius corridor_radius + 4r - 1.5r) and outside the projected gap (radius GR + r)']));
  Result.Add('blit', Lines([
    'sprite chosen by quantised size and blur (sprites.quantisation); scale s = r / rq (always <= 1)',
    'sprite canvas W x W, centre c = (W - 1) / 2; the canvas pixel u maps to the screen x = cx + (u - c) * s',
    'as a quad in pixel-centre convention: left = cx + 0.5 - W * s / 2, top = cy + 0.5 - W * s / 2, size W * s, bilinear filtering']));
  Result.Add('blend', Lines([
    'sprites and discs: premultiplied alpha, out = src + dst * (1 - src_alpha); opacity o multiplies colour and alpha',
    'background: copy; vignette and HUD: normal (straight alpha) blending']));
end;

function SpritesJSON(Hex: THexBackground; out AtlasInfo: TJSONObject): TJSONObject;
type
  TEntry = record
    Spr: TSprite;
    X, Y: integer;
  end;
var
  Kinds, Entries: TJSONArray;
  E: array of TEntry;
  i, j, k, n, ShelfX, ShelfY, ShelfH, AtlasW, AtlasH: integer;
  T: TEntry;
  Atlas: TBGRABitmap;
  Src: ^TBGRAPixel;
  Dst: PBGRAPixel;
  a: integer;
begin
  Result := TJSONObject.Create;
  Result.Add('pixels', 'sprite pixels are premultiplied while drawing; the atlas PNG stores straight alpha');
  Result.Add('canvas', Lines([
    'lw = max(1, rq * hexagon_style.line_width)',
    'g = glow.glow_strength * (glow.glow_base + (1 - glow.glow_base) * exp(-(bq / max(0.1, glow.glow_falloff))^2))',
    'front_glow becomes plain front when 200 * g < 6',
    'margin m: glow kinds: gb = rq * glow.glow_blur + bq, m = gb * 1.2 + lw * glow.glow_width + 2; others m = bq * 1.2 + lw + 2',
    'canvas size W = 2 * (ceil(rq) + ceil(m)) + 1; centre c = (W - 1) / 2',
    'hexagon = flat-top polygon: corner i at c + rq * (cos(i*60deg), sin(i*60deg)), i = 0..5',
    'blur = BGRABitmap FilterBlurRadial(radius, rbFast) (a fast radial approximation of a gaussian), applied when radius > 0.3']));
  Kinds := TJSONArray.Create;
  Kinds.Add(TJSONObject.Create(['id', 0, 'name', 'front', 'recipe', Lines([
    'face layer: polygon outline hexagon_style.rim_colour alpha rim_alpha, width lw, filled with face_colour alpha face_alpha',
    'inner hexagon radius rq * inner_size, outline inner_rim_colour alpha rim_alpha * inner_alpha, width lw * 0.5',
    'specular line corner 3 -> corner 4, specular_colour alpha rim_alpha * specular_alpha, width lw * 0.6',
    'blur the face layer by bq'])]));
  Kinds.Add(TJSONObject.Create(['id', 1, 'name', 'back', 'recipe', Lines([
    'polygon outline back_colour alpha rim_alpha * back_alpha, width lw * 0.8; blur by bq'])]));
  Kinds.Add(TJSONObject.Create(['id', 2, 'name', 'glow', 'recipe', Lines([
    'glow layer only: polygon outline glow_colour alpha 200 * min(1, g), width lw * glow_width; blur by gb'])]));
  Kinds.Add(TJSONObject.Create(['id', 3, 'name', 'dust', 'recipe', Lines([
    'filled circle radius rq, bokeh_dust.dust_colour alpha 255; blur by bq (drawn with the particle alpha as opacity)'])]));
  Kinds.Add(TJSONObject.Create(['id', 4, 'name', 'dot', 'recipe', Lines([
    'filled circle radius rq, bokeh_dust.dot_colour alpha 255; blur by bq'])]));
  Kinds.Add(TJSONObject.Create(['id', 5, 'name', 'front_glow', 'recipe', Lines([
    'glow layer (as glow) first, then the face layer of front drawn over it'])]));
  Kinds.Add(TJSONObject.Create(['id', 6, 'name', 'gate', 'recipe', Lines([
    'front_glow with rim colour = game.gate_rim_colour, face alpha = game.gate_face_alpha, glow base 0.6'])]));
  Kinds.Add(TJSONObject.Create(['id', 7, 'name', 'gate_edge', 'recipe', Lines([
    'front_glow with rim colour = game.gap_rim_colour, glow colour = game.gap_glow_colour, glow strength x 1.6,',
    'face alpha = game.gate_face_alpha, glow base 0.6'])]));
  Kinds.Add(TJSONObject.Create(['id', 8, 'name', 'gate_back', 'recipe', Lines([
    'back with back colour = game.gate_rim_colour and back alpha 0.5'])]));
  Result.Add('kinds', Kinds);
  Result.Add('quantisation', Lines([
    'size buckets grow by performance.size_step: off = -floor(ln(0.5) / ln(size_step));',
    '  si = clamp(ceil(ln(max(r, 0.5)) / ln(size_step) - 1e-4) + off, 0, 255); rq = exp((si - off) * ln(size_step))',
    'blur buckets grow by performance.blur_step: bi = 0 when blur < 0.5, else clamp(1 + round(ln(blur / 0.5) / ln(blur_step)), 1, 63);',
    '  bq = 0 or 0.5 * exp((bi - 1) * ln(blur_step))',
    'the atlas below is a coarser sample (sizes x blurs) for programs that do not draw the recipes themselves:',
    '  pick the smallest atlas size >= r (or the largest), the nearest blur, and scale by r / rq']));

  // ---- bake the atlas
  n := 0;
  SetLength(E, SpriteKindCount * Length(GfxAtlasSizes) * Length(GfxAtlasBlurs));
  for k := 0 to SpriteKindCount - 1 do
    for i := 0 to High(GfxAtlasSizes) do
      for j := 0 to High(GfxAtlasBlurs) do
      begin
        E[n].Spr := Hex.BakeSprite(k, GfxAtlasSizes[i], GfxAtlasBlurs[j]);
        Inc(n);
      end;
  // tallest first, then shelf packing 4096 wide
  for i := 0 to n - 2 do
    for j := i + 1 to n - 1 do
      if E[j].Spr.W > E[i].Spr.W then
      begin
        T := E[i];
        E[i] := E[j];
        E[j] := T;
      end;
  AtlasW := 4096;
  ShelfX := 0;
  ShelfY := 0;
  ShelfH := 0;
  for i := 0 to n - 1 do
  begin
    if ShelfX + E[i].Spr.W > AtlasW then
    begin
      ShelfX := 0;
      Inc(ShelfY, ShelfH + 1);
      ShelfH := 0;
    end;
    E[i].X := ShelfX;
    E[i].Y := ShelfY;
    Inc(ShelfX, E[i].Spr.W + 1);
    ShelfH := Max(ShelfH, E[i].Spr.W);
  end;
  AtlasH := ShelfY + ShelfH;
  Atlas := TBGRABitmap.Create(AtlasW, AtlasH, BGRAPixelTransparent);
  Entries := TJSONArray.Create;
  try
    for i := 0 to n - 1 do
      with E[i] do
      begin
        for j := 0 to Spr.W - 1 do
        begin
          Src := @Spr.Pix[j * Spr.W];
          Dst := Atlas.ScanLine[Y + j];
          Inc(Dst, X);
          for k := 0 to Spr.W - 1 do
          begin
            // premultiplied -> straight alpha for the PNG
            a := Src^.alpha;
            if a > 0 then
              Dst^ := BGRA(Min(255, Src^.red * 255 div a), Min(255, Src^.green * 255 div a),
                Min(255, Src^.blue * 255 div a), a);
            Inc(Src);
            Inc(Dst);
          end;
        end;
        Entries.Add(TJSONObject.Create(['kind', Spr.Kind, 'kind_name', SpriteKindNames[Spr.Kind],
          'rq', F(Spr.Rq), 'bq', F(Spr.Bq), 'x', X, 'y', Y, 'w', Spr.W, 'h', Spr.W]));
        Spr.Free;
      end;
    Atlas.InvalidateBitmap;
    AtlasInfo := TJSONObject.Create;
    AtlasInfo.Add('size_levels', TJSONArray.Create([F(GfxAtlasSizes[0]), F(GfxAtlasSizes[1]), F(GfxAtlasSizes[2]),
      F(GfxAtlasSizes[3]), F(GfxAtlasSizes[4]), F(GfxAtlasSizes[5]), F(GfxAtlasSizes[6]), F(GfxAtlasSizes[7]),
      F(GfxAtlasSizes[8])]));
    AtlasInfo.Add('blur_levels', TJSONArray.Create([F(GfxAtlasBlurs[0]), F(GfxAtlasBlurs[1]), F(GfxAtlasBlurs[2]),
      F(GfxAtlasBlurs[3]), F(GfxAtlasBlurs[4])]));
    AtlasInfo.Add('note', 'entry (x, y, w, h) is a square sprite canvas; its centre is ((w - 1) / 2, (h - 1) / 2)');
    AtlasInfo.Add('width', AtlasW);
    AtlasInfo.Add('height', AtlasH);
    AtlasInfo.Add('entries', Entries);
    AtlasInfo.Add('png_base64', PngBase64(Atlas));
  finally
    Atlas.Free;
  end;
  Result.Add('atlas', AtlasInfo);
end;

function ScreenLayersJSON(Hex: THexBackground): TJSONObject;
var
  O: TJSONObject;
begin
  // the engine's own background and vignette at 1280 x 720
  Hex.BuildFrame(1280, 720, [0..PassCount - 1], False);
  Result := TJSONObject.Create;
  O := TJSONObject.Create;
  O.Add('recipe', Lines([
    'fill background.base_colour (alpha 255)',
    'for i = 1..3: radial gradient from haze_i_colour to the same colour with alpha 0,',
    '  centre (W * haze_i_x, H * haze_i_y), radius max(W, H) * haze_i_radius, drawn over (BGRABitmap gamma-corrected gradient)',
    'made for the output size; it does not move with the camera']));
  O.Add('width', 1280);
  O.Add('height', 720);
  O.Add('png_base64', PngBase64(Hex.FrameBase));
  Result.Add('background', O);
  O := TJSONObject.Create;
  O.Add('recipe', Lines([
    'transparent layer; radial gradient from black alpha 0 to black alpha vignette.strength,',
    '  centre (W * centre_x, H * centre_y), radius sqrt(W^2 + H^2) * vignette.radius',
    'then a linear gradient from black alpha vignette.shadow_alpha at (0, 0) to alpha 0 at (W * shadow_end_x, H * shadow_end_y)',
    'drawn over the finished picture']));
  O.Add('width', 1280);
  O.Add('height', 720);
  O.Add('png_base64', PngBase64(Hex.FrameVignette));
  Result.Add('vignette', O);
  O := TJSONObject.Create;
  O.Add('recipe', 'white disc, premultiplied: alpha = clamp(size / 2 - 0.5 - distance from the centre, 0, 1); 64 x 64; tinted per spark');
  O.Add('size', 64);
  Result.Add('disc', O);
end;

function ReferenceFrameJSON(Hex: THexBackground): TJSONObject;
var
  Bmp: TBGRABitmap;
begin
  Result := TJSONObject.Create;
  Bmp := TBGRABitmap.Create(1, 1);
  try
    Hex.Render(Bmp, 1280, 720, [0..PassCount - 1], False, False);
    Result.Add('note', 'one frame rendered by the CPU renderer (no HUD), for checking another implementation');
    Result.Add('time', F(Hex.Time));
    Result.Add('seed', Hex.Seed);
    Result.Add('camera_position', TJSONArray.Create([F(Hex.CameraPos.X), F(Hex.CameraPos.Y), F(Hex.CameraPos.Z)]));
    Result.Add('focus_distance', F(Hex.FocusNow));
    Result.Add('width', 1280);
    Result.Add('height', 720);
    Result.Add('png_base64', PngBase64(Bmp));
  finally
    Bmp.Free;
  end;
end;

procedure UseNiceFloats;
begin
  SetJSONInstanceType(jitNumberFloat, TNiceFloat);
end;

end.
