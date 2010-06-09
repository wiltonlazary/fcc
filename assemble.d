module assemble;

import ast.types;

import tools.base: Format, New, or, and;
import tools.compat: find, abs, replace;
import tools.log;

bool isRelative(string reg) {
  return reg.find("(") != -1;
}

import parseBase; // int parsing
struct Transaction {
  enum Kind {
    Mov, Mov2, SAlloc, SFree, MathOp, Push, Pop, Compare
  }
  Kind kind;
  string toString() {
    switch (kind) {
      case Kind.Mov:     return Format("[movl ", from, " -> ", to, "]");
      case Kind.Mov2:    return Format("[movw ", from, " -> ", to, "]");
      case Kind.SAlloc:  return Format("[salloc ", size, "]");
      case Kind.SFree:   return Format("[sfree ", size, "]");
      case Kind.MathOp:  return Format("[math:", opName, " ", op1, ", ", op2, "]");
      case Kind.Push:    return Format("[push ", source, "]");
      case Kind.Pop:     return Format("[pop ", dest, "]");
      case Kind.Compare:
        if (test) return Format("[cmp/test ", op1, ", ", op2, "]");
        else return Format("[cmp ", op1, ", ", op2, "]");
    }
  }
  string toAsm() {
    switch (kind) {
      case Kind.Mov:
        if (from.isRelative() && to.isRelative()) {
          assert(usableScratch, "Cannot do relative memmove without scratch register! ");
          return Format("movl ", from, ", ", usableScratch, "\nmovl ", usableScratch, ", ", to);
        } else {
          return Format("movl ", from, ", ", to);
        }
      case Kind.Mov2:
        if (from.isRelative() && to.isRelative()) {
          assert(usableScratch, "Cannot do relative memmove without scratch register! ");
          return Format("movw ", from, ", ", usableScratch, "\nmovw ", usableScratch, ", ", to);
        } else {
          return Format("movw ", from, ", ", to);
        }
      case Kind.SAlloc:
          if (!size) return null;
          return Format("subl $", size, ", %esp");
      case Kind.SFree:
          if (!size) return null;
          return Format("addl $", size, ", %esp");
      case Kind.MathOp:
        if (opName == "addl" && op1 == "$1") return Format("incl ", op2);
        if (opName == "subl" && op1 == "$1") return Format("decl ", op2);
        return Format(opName, " ", op1, ", ", op2);
      case Kind.Push, Kind.Pop:
        auto size = type.size;
        string res;
        void addLine(string s) { if (res) res ~= "\n"; res ~= s; }
        auto mnemo = (kind == Kind.Push) ? "push" : "pop";
        // %eax
        string matchRegister(string s) {
          string reg;
          if (s.accept("%") && s.gotIdentifier(reg) && !s.length) return reg;
          else return null;
        }
        // $5 or $constant_string
        bool gotLiteral(string s, ref int num, ref string ident) {
          return s.accept("$") && (s.gotInt(num) || (s.find("(") == -1) && (ident = s, s = null, true)) && !s.length;
        }
        // 8(%eax)
        string gotMemoryOffset(string s, ref int offs) {
          string reg;
          if ((s.gotInt(offs) || (offs = 0, true)) && s.accept("(%") && s.gotIdentifier(reg) && s.accept(")")) return reg;
          else return null;
        }
        // push/pop as far as possible at that size sz, using instruction postfix pf.
        auto op = (kind == Kind.Push) ? source : dest;
        void doOp(int sz, string pf) {
          while (size >= sz) {
            addLine(Format(mnemo, pf, " ", op));
            auto s2 = op;
            int offs, num; string ident;
            if (auto reg = op.matchRegister()) {
              auto regsize = (reg[0] == 'e')?4:(reg[0] == 'r')?8:(reg[$-1]== 'l' /or/ 'h')?1:2;
              if (size != regsize) throw new Exception(Format("Can't pop/push ", type, " of ", reg, ": size mismatch! "));
            }
            else if (kind == Kind.Push && op.gotLiteral(num, ident)) {
              if (size != sz) throw new Exception(Format("Can't push ", type, " of ", ident?ident:Format(num), ": size mismatch! "));
            }
            else if (auto reg = op.gotMemoryOffset(offs)) {
              op = Format(offs - sz, "(%", reg, ")");
            }
            else
              throw new Exception("Unknown address format: '"~op~"'");
            size -= sz;
          }
        }
        // doOp(8, "r");
        doOp(4, "l");
        doOp(2, "w");
        doOp(1, "b");
        return res;
      case Kind.Compare:
        if (test) return Format("testl ", op1, ", ", op2);
        else return Format("cmpl ", op1, ", ", op2);
    }
  }
  union {
    struct { // Mov
      string from, to;
      string usableScratch;
    }
    int size;
    struct {
      string source, dest;
      Type type;
    }
    struct {
      string opName;
      string op1, op2;
      bool test;
    }
  }
}

bool debugOpts;

struct Transsection(C) {
  Transcache parent;
  string opName;
  C cond;
  int from, to;
  bool modded;
  Transaction opIndex(int i) { return parent.list[from + i]; }
  size_t length() { return to - from; }
  void replaceWith(Transaction[] withWhat) {
    if (debugOpts) logln(opName, ": ", parent.list[from .. to], " -> ", withWhat);
    parent.list = parent.list[0 .. from] ~ withWhat ~ parent.list[to .. $];
    to = from + withWhat.length;
    modded = true;
  }
  void replaceWith(Transaction withWhat) {
    if (debugOpts) logln(opName, ": ", parent.list[from .. to], " -> ", withWhat);
    parent.list = parent.list[0 .. from] ~ withWhat ~ parent.list[to .. $];
    to = from + 1;
    modded = true;
  }
  bool advance() {
    auto start = from;
    // don't recheck if not modified
    if (!modded) start = to;
    *this = parent.findMatch(opName, cond, start);
    return from != to;
  }
}

class Transcache {
  Transaction[] list;
  Transsection!(C) findMatch(C)(string opName, C cond, int from = 0) {
    for (int base = from; base < list.length; ++base) {
      if (auto len = cond(list[base .. $])) return Transsection!(C)(this, opName, cond, base, base + len, false);
    }
    return Transsection!(C)(this, opName, cond, 0, 0, false);
  }
  void opCatAssign(Transaction t) { list ~= t; }
}
