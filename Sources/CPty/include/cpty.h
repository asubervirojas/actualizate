#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>

// Lanza `path` en una pseudo terminal nueva, como lider de sesion con esa terminal como terminal
// de control (sudo y Touch ID funcionan igual que en Terminal). Devuelve el pid y deja en
// *master el descriptor del lado maestro, o -1 si falla.
pid_t cpty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                 unsigned short cols, unsigned short rows, int *master);

// Cambia el tamano de la terminal (manda SIGWINCH al proceso)
int cpty_resize(int master, unsigned short cols, unsigned short rows);

#endif
