module hello;
import sys, sdl, opengl;

c_include "stdio.h";

void quit(int code) {
  SDL_Quit();
  exit(code);
}

int resizeWindow(int w, int h) {
  if !h
    h = 1;
  auto ratio = w * 1.0 / h;
  glViewport(0, 0, w, h);
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity();
  gluPerspective(45.0, ratio, 0.1, 100.0);
  glMatrixMode(GL_MODELVIEW);
  glLoadIdentity();
  return true;
}

int initGL() {
  glShadeModel(GL_SMOOTH);
  glClearColor(0, 0, 0, 0);
  glClearDepth(1);
  glEnable(GL_DEPTH_TEST);
  glDepthFunc(GL_LEQUAL);
  glHint(GL_PERSPECTIVE_CORRECTION_HINT, GL_NICEST);
  return true;
}

context Triangles {
  alias onUsing = glBegin(GL_TRIANGLES);
  alias onExit = glEnd();
}

context Quads {
  alias onUsing = glBegin(GL_QUADS);
  alias onExit = glEnd();
}

void drawScene() {
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
  glLoadIdentity();
  glTranslatef(-1.5, 0, -6.0);
  using Triangles {
    glVertex3f( 0,  1, 0);
    glVertex3f(-1, -1, 0);
    glVertex3f( 1, -1, 0);
  }
  glTranslatef(3, 0, 0);
  using Quads {
    glVertex3f(-1,  1, 0);
    glVertex3f( 1,  1, 0);
    glVertex3f( 1, -1, 0);
    glVertex3f(-1, -1, 0);
  }
  SDL_GL_SwapBuffers();
}

struct SDL_Event {
  char type;
  int[64] filler;
}

extern(C) int SDL_PollEvent(SDL_Event*);

int update(SDL_Surface* surface) {
  SDL_Flip(surface);
  SDL_Event ev;
  while SDL_PollEvent(&ev) {
    if ev.type == 12 return 1; // QUIT
  }
  return 0;
}

int main(int argc, char** argv) {
  writeln("Hello World");
  SDL_Init(SDL_INIT_VIDEO);
  auto flags = SDL_OPENGL | SDL_GL_DOUBLEBUFFER | SDL_HWPALETTE | SDL_RESIZABLE | SDL_HWSURFACE | SDL_HWACCEL;
  SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
  auto surf = SDL_SetVideoMode(640, 480, 0, flags);
  if !surf quit(1);
  initGL();
  resizeWindow(640, 480);
  while true {
    drawScene();
    if update(surf) quit(0);
  }
}
