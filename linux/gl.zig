// gl.zig — Hand-written OpenGL function declarations for Linux frontend.
//
// Replaces @cImport of epoxy/gl.h. Functions are resolved at link time
// via libepoxy. This enables cross-compilation from macOS (no C headers needed).

// =========================================================================
// Types
// =========================================================================

pub const GLenum = c_uint;
pub const GLuint = c_uint;
pub const GLint = c_int;
pub const GLsizei = c_int;
pub const GLchar = u8;
pub const GLboolean = u8;
pub const GLfloat = f32;
pub const GLbitfield = c_uint;
pub const GLintptr = isize;
pub const GLsizeiptr = isize;

// =========================================================================
// Constants
// =========================================================================

// Shader types
pub const GL_VERTEX_SHADER: GLenum = 0x8B31;
pub const GL_FRAGMENT_SHADER: GLenum = 0x8B30;

// Shader/program status
pub const GL_COMPILE_STATUS: GLenum = 0x8B81;
pub const GL_LINK_STATUS: GLenum = 0x8B82;

// Data types
pub const GL_FLOAT: GLenum = 0x1406;
pub const GL_INT: GLenum = 0x1404;
pub const GL_UNSIGNED_INT: GLenum = 0x1405;
pub const GL_UNSIGNED_BYTE: GLenum = 0x1401;

// Boolean
pub const GL_FALSE: GLboolean = 0;
pub const GL_TRUE: GLboolean = 1;

// Primitives
pub const GL_TRIANGLES: GLenum = 0x0004;

// Textures
pub const GL_TEXTURE_2D: GLenum = 0x0DE1;
pub const GL_TEXTURE0: GLenum = 0x84C0;
pub const GL_RGBA8: GLint = 0x8058;
pub const GL_RGBA16F: GLint = 0x881A;
pub const GL_RGBA: GLenum = 0x1908;
pub const GL_RED: GLenum = 0x1903;

// Texture parameters
pub const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
pub const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
pub const GL_TEXTURE_WRAP_S: GLenum = 0x2802;
pub const GL_TEXTURE_WRAP_T: GLenum = 0x2803;
pub const GL_LINEAR: GLint = 0x2601;
pub const GL_CLAMP_TO_EDGE: GLint = 0x812F;

// Buffer targets
pub const GL_ARRAY_BUFFER: GLenum = 0x8892;

// Buffer usage
pub const GL_STREAM_DRAW: GLenum = 0x88E0;
pub const GL_DYNAMIC_DRAW: GLenum = 0x88E8;

// Blending
pub const GL_BLEND: GLenum = 0x0BE2;
pub const GL_SRC_ALPHA: GLenum = 0x0302;
pub const GL_ONE_MINUS_SRC_ALPHA: GLenum = 0x0303;
pub const GL_ONE: GLenum = 0x0001;

// Clear
pub const GL_COLOR_BUFFER_BIT: GLbitfield = 0x00004000;

// Framebuffer
pub const GL_FRAMEBUFFER: GLenum = 0x8D40;
pub const GL_COLOR_ATTACHMENT0: GLenum = 0x8CE0;

// Pixel store
pub const GL_UNPACK_ALIGNMENT: GLenum = 0x0CF5;
pub const GL_UNPACK_ROW_LENGTH: GLenum = 0x0CF2;

// =========================================================================
// Functions (resolved at link time via libepoxy)
// =========================================================================

// Shader
pub extern "c" fn glCreateShader(shaderType: GLenum) GLuint;
pub extern "c" fn glShaderSource(shader: GLuint, count: GLsizei, string: [*c]const [*c]const GLchar, length: [*c]const GLint) void;
pub extern "c" fn glCompileShader(shader: GLuint) void;
pub extern "c" fn glGetShaderiv(shader: GLuint, pname: GLenum, params: *GLint) void;
pub extern "c" fn glGetShaderInfoLog(shader: GLuint, maxLength: GLsizei, length: *GLsizei, infoLog: [*c]GLchar) void;
pub extern "c" fn glDeleteShader(shader: GLuint) void;

// Program
pub extern "c" fn glCreateProgram() GLuint;
pub extern "c" fn glAttachShader(program: GLuint, shader: GLuint) void;
pub extern "c" fn glLinkProgram(program: GLuint) void;
pub extern "c" fn glGetProgramiv(program: GLuint, pname: GLenum, params: *GLint) void;
pub extern "c" fn glGetProgramInfoLog(program: GLuint, maxLength: GLsizei, length: *GLsizei, infoLog: [*c]GLchar) void;
pub extern "c" fn glDeleteProgram(program: GLuint) void;
pub extern "c" fn glUseProgram(program: GLuint) void;

// VAO
pub extern "c" fn glGenVertexArrays(n: GLsizei, arrays: *GLuint) void;
pub extern "c" fn glBindVertexArray(array: GLuint) void;
pub extern "c" fn glDeleteVertexArrays(n: GLsizei, arrays: *const GLuint) void;

// Vertex attrib
pub extern "c" fn glEnableVertexAttribArray(index: GLuint) void;
pub extern "c" fn glVertexAttribPointer(index: GLuint, size: GLint, @"type": GLenum, normalized: GLboolean, stride: GLsizei, pointer: ?*const anyopaque) void;
pub extern "c" fn glVertexAttribIPointer(index: GLuint, size: GLint, @"type": GLenum, stride: GLsizei, pointer: ?*const anyopaque) void;

// Texture
pub extern "c" fn glGenTextures(n: GLsizei, textures: *GLuint) void;
pub extern "c" fn glBindTexture(target: GLenum, texture: GLuint) void;
pub extern "c" fn glTexImage2D(target: GLenum, level: GLint, internalformat: GLint, width: GLsizei, height: GLsizei, border: GLint, format: GLenum, @"type": GLenum, data: ?*const anyopaque) void;
pub extern "c" fn glTexSubImage2D(target: GLenum, level: GLint, xoffset: GLint, yoffset: GLint, width: GLsizei, height: GLsizei, format: GLenum, @"type": GLenum, data: ?*const anyopaque) void;
pub extern "c" fn glTexParameteri(target: GLenum, pname: GLenum, param: GLint) void;
pub extern "c" fn glDeleteTextures(n: GLsizei, textures: *const GLuint) void;
pub extern "c" fn glActiveTexture(texture: GLenum) void;

// Buffer
pub extern "c" fn glGenBuffers(n: GLsizei, buffers: *GLuint) void;
pub extern "c" fn glBindBuffer(target: GLenum, buffer: GLuint) void;
pub extern "c" fn glBufferData(target: GLenum, size: GLsizeiptr, data: ?*const anyopaque, usage: GLenum) void;
pub extern "c" fn glBufferSubData(target: GLenum, offset: GLintptr, size: GLsizeiptr, data: ?*const anyopaque) void;
pub extern "c" fn glDeleteBuffers(n: GLsizei, buffers: *const GLuint) void;

// Framebuffer
pub extern "c" fn glGenFramebuffers(n: GLsizei, ids: *GLuint) void;
pub extern "c" fn glBindFramebuffer(target: GLenum, framebuffer: GLuint) void;
pub extern "c" fn glFramebufferTexture2D(target: GLenum, attachment: GLenum, textarget: GLenum, texture: GLuint, level: GLint) void;
pub extern "c" fn glDeleteFramebuffers(n: GLsizei, framebuffers: *const GLuint) void;

// State
pub extern "c" fn glViewport(x: GLint, y: GLint, width: GLsizei, height: GLsizei) void;
pub extern "c" fn glClearColor(red: GLfloat, green: GLfloat, blue: GLfloat, alpha: GLfloat) void;
pub extern "c" fn glClear(mask: GLbitfield) void;
pub extern "c" fn glEnable(cap: GLenum) void;
pub extern "c" fn glDisable(cap: GLenum) void;
pub extern "c" fn glBlendFunc(sfactor: GLenum, dfactor: GLenum) void;

// Pixel store
pub extern "c" fn glPixelStorei(pname: GLenum, param: GLint) void;

// Draw
pub extern "c" fn glDrawArrays(mode: GLenum, first: GLint, count: GLsizei) void;
