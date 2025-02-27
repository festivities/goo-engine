
#pragma BLENDER_REQUIRE(common_math_lib.glsl)
#pragma BLENDER_REQUIRE(common_math_geom_lib.glsl)
#pragma BLENDER_REQUIRE(raytrace_lib.glsl)
#pragma BLENDER_REQUIRE(ltc_lib.glsl)

#extension GL_ARB_texture_gather : enable

#ifndef MAX_CASCADE_NUM
#  define MAX_CASCADE_NUM 4
#endif

/* ---------------------------------------------------------------------- */
/** \name Structure
 * \{ */

struct LightData {
  vec4 position_influence;     /* w : InfluenceRadius (inversed and squared) */
  vec4 color_influence_volume; /* w : InfluenceRadius but for Volume power */
  vec4 spotdata_radius_shadow; /* x : spot size, y : spot blend, z : radius, w: shadow id */
  vec4 rightvec_sizex;         /* xyz: Normalized up vector, w: area size X or spot scale X */
  vec4 upvec_sizey;            /* xyz: Normalized right vector, w: area size Y or spot scale Y */
  vec4 forwardvec_type;        /* xyz: Normalized forward vector, w: Light Type */
  vec4 diff_spec_volume;       /* xyz: Diffuse/Spec/Volume power, w: radius for volumetric. */
  ivec4 light_group_bits;     /* x : light groups, yzw : unused */
};

/* convenience aliases */
#define l_color color_influence_volume.rgb
#define l_diff diff_spec_volume.x
#define l_spec diff_spec_volume.y
#define l_volume diff_spec_volume.z
#define l_volume_radius diff_spec_volume.w
#define l_position position_influence.xyz
#define l_influence position_influence.w
#define l_influence_volume color_influence_volume.w
#define l_sizex rightvec_sizex.w
#define l_sizey upvec_sizey.w
#define l_right rightvec_sizex.xyz
#define l_up upvec_sizey.xyz
#define l_forward forwardvec_type.xyz
#define l_type forwardvec_type.w
#define l_spot_size spotdata_radius_shadow.x
#define l_spot_blend spotdata_radius_shadow.y
#define l_radius spotdata_radius_shadow.z
#define l_shadowid spotdata_radius_shadow.w

struct ShadowData {
  vec4 near_far_bias_id;
  vec4 contact_shadow_data;
};

struct ShadowCubeData {
  mat4 shadowmat;
  vec4 position;
};

struct ShadowCascadeData {
  mat4 shadowmat[MAX_CASCADE_NUM];
  vec4 split_start_distances;
  vec4 split_end_distances;
  vec4 shadow_vec_id;
};

/* convenience aliases */
#define sh_near near_far_bias_id.x
#define sh_far near_far_bias_id.y
#define sh_bias near_far_bias_id.z
#define sh_data_index near_far_bias_id.w
#define sh_contact_dist contact_shadow_data.x
#define sh_contact_offset contact_shadow_data.y
#define sh_contact_spread contact_shadow_data.z
#define sh_contact_thickness contact_shadow_data.w
#define sh_shadow_vec shadow_vec_id.xyz
#define sh_tex_index shadow_vec_id.w

/** \} */

/* ---------------------------------------------------------------------- */
/** \name Resources
 * \{ */

layout(std140) uniform shadow_block
{
  ShadowData shadows_data[MAX_SHADOW];
  ShadowCubeData shadows_cube_data[MAX_SHADOW_CUBE];
  ShadowCascadeData shadows_cascade_data[MAX_SHADOW_CASCADE];
};

layout(std140) uniform light_block
{
  LightData lights_data[MAX_LIGHT];
};

uniform depth2DArrayShadow shadowCubeTexture;
uniform depth2DArrayShadow shadowCascadeTexture;

uniform usampler2DArray shadowCubeIDTexture;
uniform usampler2DArray shadowCascadeIDTexture;

uniform ivec4 lightGroups;
uniform ivec4 lightGroupShadows;

/** \} */

/* ---------------------------------------------------------------------- */
/** \name Shadow Functions
 * \{ */

/* type */
#define POINT 0.0
#define SUN 1.0
#define SPOT 2.0
#define AREA_RECT 4.0
/* Used to define the area light shape, doesn't directly correspond to a Blender light type. */
#define AREA_ELLIPSE 100.0

float cubeFaceIndexEEVEE(vec3 P)
{
  vec3 aP = abs(P);
  if (all(greaterThan(aP.xx, aP.yz))) {
    return (P.x > 0.0) ? 0.0 : 1.0;
  }
  else if (all(greaterThan(aP.yy, aP.xz))) {
    return (P.y > 0.0) ? 2.0 : 3.0;
  }
  else {
    return (P.z > 0.0) ? 4.0 : 5.0;
  }
}

vec2 cubeFaceCoordEEVEE(vec3 P, float face, float scale)
{
  if (face < 2.0) {
    return (P.zy / P.x) * scale * vec2(-0.5, -sign(P.x) * 0.5) + 0.5;
  }
  else if (face < 4.0) {
    return (P.xz / P.y) * scale * vec2(sign(P.y) * 0.5, 0.5) + 0.5;
  }
  else {
    return (P.xy / P.z) * scale * vec2(0.5, -sign(P.z) * 0.5) + 0.5;
  }
}

vec2 cubeFaceCoordEEVEE(vec3 P, float face, sampler2DArray tex)
{
  /* Scaling to compensate the 1px border around the face. */
  float cube_res = float(textureSize(tex, 0).x);
  float scale = (cube_res) / (cube_res + 1.0);
  return cubeFaceCoordEEVEE(P, face, scale);
}

vec2 cubeFaceCoordEEVEE(vec3 P, float face, sampler2DArrayShadow tex)
{
  /* Scaling to compensate the 1px border around the face. */
  float cube_res = float(textureSize(tex, 0).x);
  float scale = (cube_res) / (cube_res + 1.0);
  return cubeFaceCoordEEVEE(P, face, scale);
}

vec4 sample_cube(sampler2DArray tex, vec3 cubevec, float cube)
{
  /* Manual Shadow Cube Layer indexing. */
  float face = cubeFaceIndexEEVEE(cubevec);
  vec2 uv = cubeFaceCoordEEVEE(cubevec, face, tex);

  vec3 coord = vec3(uv, cube * 6.0 + face);
  return texture(tex, coord);
}

vec4 sample_cascade(sampler2DArray tex, vec2 co, float cascade_id)
{
  return texture(tex, vec3(co, cascade_id));
}

/* Some driver poorly optimize this code. Use direct reference to matrices. */
#define sd(x) shadows_data[x]
#define scube(x) shadows_cube_data[x]
#define scascade(x) shadows_cascade_data[x]

/* HACK (Late) disable ID sampling on shaders that don't support it.
TODO check which cases this actually is */
#ifdef ObjectHash
/*
  Gather samples and manually compare against the ObjectHash uniform, then interpolate the results.
*/
float sample_ID_texture(usampler2DArray TEX_ID, vec3 coord, bool match) 
{
  uvec4 id_kernel = textureGather(TEX_ID, coord);
  vec4 matches;
  if (match) {
    matches = vec4(equal(id_kernel, uvec4(ObjectHash)));
  } else {
    matches = vec4(notEqual(id_kernel, uvec4(ObjectHash)));
  }

  ivec3 tex_size = textureSize(TEX_ID, 0);
  // No idea why an extra 0.00195 offset is required. WTF?
  vec2 fra = fract((coord.xy * tex_size.xy) + vec2(0.50195, 0.50195));

  return mix(
    mix(matches.w, matches.z, fra.x), 
    mix(matches.x, matches.y, fra.x), 
    fra.y
  );
}
#else
float sample_ID_texture(usampler2DArray TEX_ID, vec3 coord, bool match)
{
  return 1.0;
}
#endif

float sample_cube_shadow(int shadow_id, vec3 P, bool match_shadow_id)
{
  int data_id = int(sd(shadow_id).sh_data_index);
  vec3 cubevec = transform_point(scube(data_id).shadowmat, P);
  float dist = max(sd(shadow_id).sh_near, max_v3(abs(cubevec)) - sd(shadow_id).sh_bias);
  dist = buffer_depth(true, dist, sd(shadow_id).sh_far, sd(shadow_id).sh_near);
  /* Manual Shadow Cube Layer indexing. */
  /* TODO: Shadow Cube Array. */
  float face = cubeFaceIndexEEVEE(cubevec);
  vec2 coord = cubeFaceCoordEEVEE(cubevec, face, shadowCubeTexture);
  /* tex_id == data_id for cube shadowmap */
  float tex_id = float(data_id);

  vec4 coord_f = vec4(coord, tex_id * 6.0 + face, dist);

#ifdef USE_SHADOW_ID
  return min(sample_ID_texture(shadowCubeIDTexture, coord_f.xyz, match_shadow_id) + texture(shadowCubeTexture, coord_f), 1.0);
#else
  return texture(shadowCubeTexture, coord_f);
#endif
}

float sample_cascade_shadow(int shadow_id, vec3 P, bool match_shadow_id)
{
  int data_id = int(sd(shadow_id).sh_data_index);
  float tex_id = scascade(data_id).sh_tex_index;
  vec4 view_z = vec4(dot(P - cameraPos, cameraForward));
  vec4 weights = 1.0 - smoothstep(scascade(data_id).split_end_distances,
                                  scascade(data_id).split_start_distances.yzwx,
                                  view_z);
  float tot_weight = dot(weights.xyz, vec3(1.0));

  int cascade = int(clamp(tot_weight, 0.0, 3.0));
  float blend = fract(tot_weight);
  float vis = weights.w;
  vec4 coord, shpos;
  /* Main cascade. */
  shpos = scascade(data_id).shadowmat[cascade] * vec4(P, 1.0);
  coord = vec4(shpos.xy, tex_id + float(cascade), shpos.z - sd(shadow_id).sh_bias);
#ifdef USE_SHADOW_ID
  float id_sample = sample_ID_texture(shadowCascadeIDTexture, coord.xyz, match_shadow_id);
  vis += min(texture(shadowCascadeTexture, coord) + id_sample, 1.0)  * (1.0 - blend);
#else
  vis += texture(shadowCascadeTexture, coord) * (1.0 - blend);
#endif

  cascade = min(3, cascade + 1);
  /* Second cascade. */
  shpos = scascade(data_id).shadowmat[cascade] * vec4(P, 1.0);
  coord = vec4(shpos.xy, tex_id + float(cascade), shpos.z - sd(shadow_id).sh_bias);
#ifdef USE_SHADOW_ID
  id_sample = sample_ID_texture(shadowCascadeIDTexture, coord.xyz, match_shadow_id);
  vis += min(texture(shadowCascadeTexture, coord) + id_sample, 1.0) * blend;
#else
  vis += texture(shadowCascadeTexture, coord) * blend;
#endif

  return saturate(vis);
}
#undef sd
#undef scube
#undef scsmd

/** \} */

/* ---------------------------------------------------------------------- */
/** \name Light Functions
 * \{ */

/* From Frostbite PBR Course
 * Distance based attenuation
 * http://www.frostbite.com/wp-content/uploads/2014/11/course_notes_moving_frostbite_to_pbr.pdf */
float distance_attenuation(float dist_sqr, float inv_sqr_influence)
{
  float factor = dist_sqr * inv_sqr_influence;
  float fac = saturate(1.0 - factor * factor);
  return fac * fac;
}

float spot_attenuation(LightData ld, vec3 l_vector)
{
  float z = dot(ld.l_forward, l_vector.xyz);
  vec3 lL = l_vector.xyz / z;
  float x = dot(ld.l_right, lL) / ld.l_sizex;
  float y = dot(ld.l_up, lL) / ld.l_sizey;
  float ellipse = inversesqrt(1.0 + x * x + y * y);
  float spotmask = smoothstep(0.0, 1.0, (ellipse - ld.l_spot_size) / ld.l_spot_blend);
  return spotmask;
}

float light_attenuation(LightData ld, vec4 l_vector, ivec4 light_groups)
{
  float vis = 1.0;
#if !defined(VOLUME_LIGHTING) // && !defined(STEP_RESOLVE)
  if (
    (ld.light_group_bits.x & light_groups.x) == 0
     && (ld.light_group_bits.y & light_groups.y) == 0
     && (ld.light_group_bits.z & light_groups.z) == 0
     && (ld.light_group_bits.w & light_groups.w) == 0
    ) {
    return 0.0;
  }
#endif
  if (ld.l_type == SPOT) {
    vis *= spot_attenuation(ld, l_vector.xyz);
  }
  if (ld.l_type >= SPOT) {
    vis *= step(0.0, -dot(l_vector.xyz, ld.l_forward));
  }
  if (ld.l_type != SUN) {
#ifdef VOLUME_LIGHTING
    vis *= distance_attenuation(l_vector.w * l_vector.w, ld.l_influence_volume);
#else
    vis *= distance_attenuation(l_vector.w * l_vector.w, ld.l_influence);
#endif
  }
  return vis;
}

float light_shadowing(LightData ld, vec3 P, float vis, ivec4 light_group_shadows)
{
#if !defined(VOLUMETRICS) || defined(VOLUME_SHADOW)
  if (ld.l_shadowid >= 0.0 && vis > 0.001 && !(
        (ld.light_group_bits.x & light_group_shadows.x) == 0
     && (ld.light_group_bits.y & light_group_shadows.y) == 0
     && (ld.light_group_bits.z & light_group_shadows.z) == 0
     && (ld.light_group_bits.w & light_group_shadows.w) == 0) 
  ) 
    {
      if (ld.l_type == SUN) {
        vis *= sample_cascade_shadow(int(ld.l_shadowid), P, true);
      }
      else {
        vis *= sample_cube_shadow(int(ld.l_shadowid), P, true);
      }
  }
#endif
  return vis;
}

#ifndef VOLUMETRICS
float light_contact_shadows(LightData ld, vec3 P, vec3 vP, vec3 vNg, float rand_x, float vis, ivec4 light_group_shadows)
{
  if (ld.l_shadowid >= 0.0 && vis > 0.001 && !(
  (ld.light_group_bits.x & light_group_shadows.x) == 0
  && (ld.light_group_bits.y & light_group_shadows.y) == 0
  && (ld.light_group_bits.z & light_group_shadows.z) == 0
  && (ld.light_group_bits.w & light_group_shadows.w) == 0)
  ) {
    ShadowData sd = shadows_data[int(ld.l_shadowid)];
    /* Only compute if not already in shadow. */
    if (sd.sh_contact_dist > 0.0) {
      /* Contact Shadows. */
      Ray ray;

      if (ld.l_type == SUN) {
        ray.direction = shadows_cascade_data[int(sd.sh_data_index)].sh_shadow_vec *
                        sd.sh_contact_dist;
      }
      else {
        ray.direction = shadows_cube_data[int(sd.sh_data_index)].position.xyz - P;
        ray.direction *= saturate(sd.sh_contact_dist * safe_rcp(length(ray.direction)));
      }

      ray.direction = transform_direction(ViewMatrix, ray.direction);
      ray.origin = vP + vNg * sd.sh_contact_offset;

      RayTraceParameters params;
      params.thickness = sd.sh_contact_thickness;
      params.jitter = rand_x;
      params.trace_quality = 0.1;
      params.roughness = 0.001;

      vec3 hit_position_unused;

      if (raytrace(ray, params, false, false, hit_position_unused)) {
        return 0.0;
      }
    }
  }
  return 1.0;
}
#endif /* VOLUMETRICS */

float light_visibility(LightData ld, vec3 P, vec4 l_vector, ivec4 light_groups, ivec4 light_group_shadows)
{
  float l_atten = light_attenuation(ld, l_vector, light_groups);
  return light_shadowing(ld, P, l_atten, light_group_shadows);
}

float light_diffuse(LightData ld, vec3 N, vec3 V, vec4 l_vector)
{
  if (ld.l_type == AREA_RECT) {
    vec3 corners[4];
    corners[0] = normalize((l_vector.xyz + ld.l_right * -ld.l_sizex) + ld.l_up * ld.l_sizey);
    corners[1] = normalize((l_vector.xyz + ld.l_right * -ld.l_sizex) + ld.l_up * -ld.l_sizey);
    corners[2] = normalize((l_vector.xyz + ld.l_right * ld.l_sizex) + ld.l_up * -ld.l_sizey);
    corners[3] = normalize((l_vector.xyz + ld.l_right * ld.l_sizex) + ld.l_up * ld.l_sizey);

    return ltc_evaluate_quad(corners, N);
  }
  else if (ld.l_type == AREA_ELLIPSE) {
    vec3 points[3];
    points[0] = (l_vector.xyz + ld.l_right * -ld.l_sizex) + ld.l_up * -ld.l_sizey;
    points[1] = (l_vector.xyz + ld.l_right * ld.l_sizex) + ld.l_up * -ld.l_sizey;
    points[2] = (l_vector.xyz + ld.l_right * ld.l_sizex) + ld.l_up * ld.l_sizey;

    return ltc_evaluate_disk(N, V, mat3(1.0), points);
  }
  else {
    float radius = ld.l_radius;
    radius /= (ld.l_type == SUN) ? 1.0 : l_vector.w;
    vec3 L = (ld.l_type == SUN) ? -ld.l_forward : (l_vector.xyz / l_vector.w);

    return ltc_evaluate_disk_simple(radius, dot(N, L));
  }
}

float light_specular(LightData ld, vec4 ltc_mat, vec3 N, vec3 V, vec4 l_vector)
{
  if (ld.l_type == AREA_RECT) {
    vec3 corners[4];
    corners[0] = (l_vector.xyz + ld.l_right * -ld.l_sizex) + ld.l_up * ld.l_sizey;
    corners[1] = (l_vector.xyz + ld.l_right * -ld.l_sizex) + ld.l_up * -ld.l_sizey;
    corners[2] = (l_vector.xyz + ld.l_right * ld.l_sizex) + ld.l_up * -ld.l_sizey;
    corners[3] = (l_vector.xyz + ld.l_right * ld.l_sizex) + ld.l_up * ld.l_sizey;

    ltc_transform_quad(N, V, ltc_matrix(ltc_mat), corners);

    return ltc_evaluate_quad(corners, vec3(0.0, 0.0, 1.0));
  }
  else {
    bool is_ellipse = (ld.l_type == AREA_ELLIPSE);
    float radius_x = is_ellipse ? ld.l_sizex : ld.l_radius;
    float radius_y = is_ellipse ? ld.l_sizey : ld.l_radius;

    vec3 L = (ld.l_type == SUN) ? -ld.l_forward : l_vector.xyz;
    vec3 Px = ld.l_right;
    vec3 Py = ld.l_up;

    if (ld.l_type == SPOT || ld.l_type == POINT) {
      make_orthonormal_basis(l_vector.xyz / l_vector.w, Px, Py);
    }

    vec3 points[3];
    points[0] = (L + Px * -radius_x) + Py * -radius_y;
    points[1] = (L + Px * radius_x) + Py * -radius_y;
    points[2] = (L + Px * radius_x) + Py * radius_y;

    return ltc_evaluate_disk(N, V, ltc_matrix(ltc_mat), points);
  }
}

/** \} */
