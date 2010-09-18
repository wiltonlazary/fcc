module lesson06;

import sys;

/*
 * This code was created by Jeff Molofee '99 
 * (ported to Linux/SDL by Ti Leggett '01)
 * (ported to fcc by feep '10)
 *
 * If you've found this code useful, please let me know.
 *
 * Visit Jeff at http://nehe.gamedev.net/
 * 
 * or for port-specific comments, questions, bugreports etc. 
 * email to leggett@eecs.tulane.edu
 */

c_include "stdio.h";
c_include "stdlib.h";
c_include "GL/gl.h";
c_include "GL/glu.h";
c_include "SDL/SDL.h";

alias SCREEN_WIDTH = 640;
alias SCREEN_HEIGHT = 480;
alias SCREEN_BPP = 16;

SDL_Surface* surface;

void quit(int code) {
  SDL_Quit();
  exit(code);
}

void resizeWindow(int width, height) {
  if !height height = 1;
  auto ratio = width * 1.0 / height;
  glViewport(0, 0, width, height);
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity();
  gluPerspective(45.0, ratio, 0.1, 100);
  glMatrixMode(GL_MODELVIEW);
  glLoadIdentity();
}

void handleKeyPress(SDL_keysym* keysym )
{
  if (keysym.sym == SDLK_ESCAPE) quit(0);
  if (keysym.sym == SDLK_F1) SDL_WM_ToggleFullScreen(surface);
}

context rot {
  float x, y, z;
}

GLuint[1] texture;

alias SDL_RWops = void;
extern(C) SDL_RWops* SDL_RWFromFile(char* file, char* mode);
extern(C) SDL_Surface* SDL_LoadBMP_RW(SDL_RWops* src, int freesrc);

void loadGLTextures() {
  auto status = false;
  auto TextureImage = [SDL_LoadBMP_RW(SDL_RWFromFile("data/nehe.bmp", "rb"), 1)];
  if TextureImage[0] {
    status = true;
    glGenTextures (1, &texture[0]);
    glBindTexture (GL_TEXTURE_2D, texture[0]);
    using *TextureImage[0]
      glTexImage2D (GL_TEXTURE_2D, 0, 3, w, h, 0, GL_BGR, GL_UNSIGNED_BYTE, pixels);
    
    glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri (GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    if TextureImage[0]
      SDL_FreeSurface TextureImage[0];
  }
}

void initGL() {
  glShadeModel(GL_SMOOTH);
  loadGLTextures;
  glEnable GL_TEXTURE_2D;
  glClearColor(0, 0, 0, 0.5);
  glClearDepth(1);
  glEnable GL_DEPTH_TEST;
  glDepthFunc(GL_LEQUAL);
  glHint(GL_PERSPECTIVE_CORRECTION_HINT, GL_NICEST);
}

context timing {
  int t0, frames;
}

alias X = (1, 0, 0);
alias Y = (0, 1, 0);
alias Z = (0, 0, 1);

void drawGLScene() {
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
  glLoadIdentity;
  glTranslatef (0, 0, -5);
  using rot {
    glRotatef (x, X);
    glRotatef (y, Y);
    glRotatef (z, Z);
  }
  
  glBindTexture (GL_TEXTURE_2D, texture[0]);
  
  auto corners = cross [1, -1]^3;
  /*
   1  1  1 |0
   1  1 -1 |1
   1 -1  1 |2
   1 -1 -1 |3
  -1  1  1 |4
  -1  1 -1 |5
  -1 -1  1 |6
  -1 -1 -1 |7
  */
  glBegin GL_QUADS;
    while auto tup <- [
                  // front face
                  ((0, 1), 6), ((1, 1), 2), ((1, 0), 0), ((0, 0), 4),
                  // back face
                  ((0, 0), 7), ((0, 1), 5), ((1, 1), 1), ((1, 0), 3),
                  // top face
                  ((1, 1), 5), ((1, 0), 4), ((0, 0), 0), ((0, 1), 1),
                  // bottom face
                  ((0, 1), 7), ((1, 1), 3), ((1, 0), 2), ((0, 0), 6),
                  // right face
                  ((0, 0), 3), ((0, 1), 1), ((1, 1), 0), ((1, 0), 2),
                  // left face
                  ((1, 0), 7), ((0, 0), 6), ((0, 1), 4), ((1, 1), 5)]
    {
      glTexCoord2f tup[0];
      glVertex3f corners[tup[1]];
    }
    using rot {
      x = x + 0.01;
      y = y + 0.006;
      z = z + 0.013;
    }
  glEnd;
  
  SDL_GL_SwapBuffers();
  timing.frames++;
  auto t = SDL_GetTicks();
  if (t - timing.t0 >= 5000) using timing {
    auto seconds = (t - t0) / 1000.0;
    auto fps = frames / seconds;
    writeln("$frames frames in $seconds seconds = $fps fps. ");
    t0 = t;
    frames = 0;
  }
}

char[] toString(char* p) {
  return p[0..strlen(p)];
}

int main(int argc, char** argv) {
  SDL_Init(SDL_INIT_VIDEO);
  auto videoFlags = SDL_OPENGL | SDL_GL_DOUBLEBUFFER | SDL_HWPALETTE | SDL_RESIZABLE | SDL_HWSURFACE | SDL_HWACCEL;
  SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
  surface = SDL_SetVideoMode(SCREEN_WIDTH, SCREEN_HEIGHT, SCREEN_BPP, videoFlags);
  if (!surface) {
    writeln("Video mode set failed: $(toString(SDL_GetError()))");
    quit(1);
  }
  initGL();
  resizeWindow(SCREEN_WIDTH, SCREEN_HEIGHT);
  bool done;
  while !done {
    SDL_Event ev;
    while SDL_PollEvent(&ev) {
      if (ev.type == SDL_VIDEORESIZE) {
        surface = SDL_SetVideoMode(ev.resize.w, ev.resize.h, 16, videoFlags);
        resizeWindow(ev.resize.w, ev.resize.h);
      }
      if (ev.type == SDL_KEYDOWN) {
        handleKeyPress(&ev.key.keysym);
      }
      if (ev.type == SDL_QUIT) {
        done = true;
      }
    }
    drawGLScene();
  }
  quit(0);
  return 0;
}