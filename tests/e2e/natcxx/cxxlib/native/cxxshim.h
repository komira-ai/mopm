#ifndef CXXSHIM_H
#define CXXSHIM_H

#ifdef __cplusplus
extern "C" {
#endif

/* 42, computed with std::string (12), operator new[] (1+2+3+4) and a virtual call (20). */
int cxx_answer(void);

#ifdef __cplusplus
}
#endif

#endif
