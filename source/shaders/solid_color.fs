//version tag will be prepended at runtime since it varies depending on build target
#ifdef GL_ES
precision mediump float;
#endif
in vec2 fragTexCoord; 
uniform sampler2D texture0;
uniform vec3 shade;
out vec4 finalColor;

void main() {
    vec4 orig = texture(texture0,fragTexCoord);
    finalColor = vec4(shade.rgb,orig.a);
}