#include "cxxshim.h"

#include <string>

namespace {

struct Base {
    virtual ~Base() {}
    virtual int value() const = 0;
};

struct Twenty : Base {
    int value() const override { return 20; }
};

}  // namespace

extern "C" int cxx_answer(void) {
    std::string s = "hello, ";
    s += "world";
    int *a = new int[4];
    int sum = 0;
    for (int i = 0; i < 4; i++) {
        a[i] = i + 1;
        sum += a[i];
    }
    delete[] a;
    Base *b = new Twenty();
    int v = b->value();
    delete b;
    return static_cast<int>(s.size()) + sum + v;
}
