module ast.c_bind;

// Optimized for GL.h and SDL.h; may not work for others!! 
import ast.base, ast.modules, ast.structure, ast.casting, ast.static_arrays, ast.tuples: AstTuple = Tuple;

import tools.compat, tools.functional;
alias asmfile.startsWith startsWith;

extern(C) {
  int pipe(int*);
  int close(int);
}

string buf;
string readStream(InputStream IS) {
  if (!buf) buf = new char[1024*1024];
  int reslen;
  ubyte[1024] buffer;
  int i;
  do {
    i = IS.read(buffer);
    if (i < 0) throw new Exception(Format("Read error: ", i));
    while (buf.length < reslen + i)
      buf.length = cast(int) (buf.length * 2);
    buf[reslen .. reslen + i] = cast(string) buffer[0 .. i];
    reslen += i;
  } while (i);
  auto res = buf[0 .. reslen];
  buf = buf[reslen .. $];
  return res;
}

string readback(string cmd) {
  // logln("> ", cmd);
  int[2] fd; // read end, write end
  if (-1 == pipe(fd.ptr)) throw new Exception(Format("Can't open pipe! "));
  scope(exit) close(fd[0]);
  auto cmdstr = Format(cmd, " >&", fd[1], " &");
  system(toStringz(cmdstr));
  close(fd[1]);
  scope fs = new CFile(fdopen(fd[0], "r"), FileMode.In);
  return readStream(fs);
}

import
  ast.aliasing, ast.pointer, ast.fun, ast.namespace, ast.int_literal,
  ast.fold, ast.opers;
import tools.time;

class LateType : IType, TypeProxy {
  IType me;
  void delegate() tryResolve;
  this() { }
  string toString() { if (!me) return "(LateType, unresolved)"; return Format("(LateType ", me, ")"); }
  void needMe() {
    if (!me) tryResolve();
    assert(!!me);
  }
  override {
    int size() { needMe; return me.size; }
    ubyte[] initval() { needMe; return me.initval; }
    int opEquals(IType it) {
      needMe;
      return it == me;
    }
    string mangle() { needMe; return me.mangle(); }
    IType actualType() { needMe; return me; }
  }
}

const c_tree_expr = "tree.expr"
  " >tree.expr.vardecl >tree.expr.type_stringof >tree.expr.type_mangleof"
  " >tree.expr.classid >tree.expr.iter >tree.expr.iter_range"
  " >tree.expr.new >tree.expr.eval >tree.expr.cast >tree.expr.veccon"
  " >tree.expr.cast_explicit_default >tree.expr.cast_convert"
  " >tree.expr.scoped >tree.expr.stringex >tree.expr.dynamic_class_cast"
  " >tree.expr.properties";

void parseHeader(string filename, string src, ParseCb rest) {
  auto start_time = sec();
  string newsrc;
  bool inEnum;
  string[] buffer;
  void flushBuffer() { foreach (def; buffer) newsrc ~= def ~ ";"; buffer = null; }
  foreach (line; src.split("\n")) {
    // special handling for fenv.h; shuffle #defines past the enum
    if (line.startsWith("enum")) inEnum = true;
    if (line.startsWith("}")) { inEnum = false; newsrc ~= line; flushBuffer; continue; }
    if (line.startsWith("#define")) { if (inEnum) buffer ~= line; else {  newsrc ~= line; newsrc ~= ";"; } }
    if (line.startsWith("#")) continue;
    newsrc ~= line ~ " ";
  }
  // no need to remove comments; the preprocessor already did that
  auto statements = newsrc.split(";") /map/ &strip;
  // mini parser
  Named[string] cache;
  auto myNS = new MiniNamespace("parse_header");
  myNS.sup = namespace();
  myNS.internalMode = true;
  namespace.set(myNS);
  scope(exit) namespace.set(myNS.sup);
  void add(string name, Named n) {
    if (myNS.lookup(name)) { return; } // duplicate definition. meh.
    auto ea = fastcast!(ExprAlias)~ n;
    if (ea) {
      if (!gotImplicitCast(ea.base, (IType it) { return !fastcast!(AstTuple) (it); })) {
        logln("Weird thing ", ea);
        asm { int 3; }
      }
    }
    // logln("add ", name, " <- ", n);
    myNS._add(name, fastcast!(Object)~ n);
    if (auto ns = fastcast!(Namespace) (n)) ns.sup = null; // lol
    cache[name] = n;
  }
  
  void delegate()[] resolves;
  scope(success)
    foreach (dg; resolves)
      dg();
  IType matchSimpleType(ref string text) {
    bool accept(string s) {
      auto t2 = text;
      while (s.length) {
        string part1, part2;
        if (!s.gotIdentifier(part1)) return false;
        if (!t2.gotIdentifier(part2)) return false;
        if (part1 != part2) return false;
        s = s.strip();
      }
      text = t2;
      return true;
    }
    if (auto rest = text.strip().startsWith("...")) { text = rest; return Single!(Variadic); }
    if (accept("unsigned long int"))  return Single!(SysInt);
    if (accept("unsigned long long int") || accept("unsigned long long"))
      return Single!(Long);
    if (accept("long long int") || accept("long long"))
      return Single!(Long);
    if (accept("unsigned int") || accept("signed int") || accept("long int") || accept("int")) return Single!(SysInt);
    if (accept("unsigned char") || accept("signed char") || accept("char")) return Single!(Char);
    if (accept("signed short int") || accept("unsigned short int") || accept("unsigned short") || accept("short int") || accept("short"))
      return Single!(Short);
    if (accept("unsigned long")) return Single!(SizeT);
    if (accept("void")) return Single!(Void);
    if (accept("float")) return Single!(Float);
    if (accept("double")) return Single!(Double);
    if (accept("struct")) {
      string name;
      if (!text.gotIdentifier(name))
        return Single!(Void);
      if (auto p = name in cache) return fastcast!(IType)~ *p;
      else {
        auto lt = new LateType;
        auto dg = stuple(lt, name, &cache) /apply/
        delegate void(LateType lt, string name, typeof(cache)* cachep) {
          if (auto p = name in *cachep) lt.me = fastcast!(IType)~ *p;
          // else assert(false, "'"~name~"' didn't resolve! ");
          else lt.me = Single!(Void);
        };
        lt.tryResolve = dg;
        resolves ~= dg;
        return lt;
      }
    }
    string id;
    if (!text.gotIdentifier(id)) return null;
    if (auto p = id in cache) return fastcast!(IType)~ *p;
    return null;
  }
  IType matchType(ref string text) {
    text.accept("const");
    text.accept("__const");
    if (auto ty = matchSimpleType(text)) {
      while (text.accept("*")) ty = new Pointer(ty);
      return ty;
    } else return null;
  }
  IType matchParam(ref string text) {
    IType ty = matchType(text);
    if (!ty) return null;
    text.accept("__restrict");
    text.accept("__const");
    string id;
    gotIdentifier(text, id);
    if (auto sa = fastcast!(StaticArray)~ resolveType(ty)) {
      ty = new Pointer(sa.elemType);
    }
    redo:if (text.startsWith("[")) {
      ty = new Pointer(ty);
      text.slice("]");
      goto redo;
    }
    text.accept(",");
    return ty;
  }
  bool readCExpr(ref string source, Expr* res) {
    source = mystripl(source);
    if (!source.length) return false;
    auto s2 = source;
    // fairly obvious what this is
    if (source.endsWith("_TYPE") || s2.matchType()) return false;
    int i;
    s2 = source;
    if (s2.gotInt(i)) {
      if (auto rest = s2.startsWith("U")) s2 = rest; // TODO
      if (s2.accept("LL")) return false; // long long
      s2.accept("L");
      if (!s2.length) {
        *res = new IntExpr(i);
        source = s2;
        return true;
      }
    }
    s2 = source;
    if (s2.startsWith("__PRI")) return false; // no chance to parse
    s2 = source;
    string ident;
    if (s2.gotIdentifier(ident) && !s2.length) {
      // float science notation constants
      if (ident.length > 2) {
        if (ident[0] == 'e' || ident[0] == 'E')
          if (ident[1] == '+' || ident[1] == '-') return false;
        if (ident[0] == '1' && (ident[1] == 'e' || ident[1] == 'E'))
          if (ident[2] == '+' || ident[2] == '-') return false;
      }
      if (auto p = ident in cache) {
        if (auto ex = fastcast!(Expr)~ *p) {
          *res = ex;
          source = null;
          return true;
        }
        return false;
      }
      // logln("IDENT ", ident);
    }
    s2 = source;
    if (s2.startsWith("__attribute__ ((")) s2 = s2.between("))", "");
    // logln(" @ '", source, "'");
    s2 = s2.mystripl();
    if (!s2.length) return false;
    if (!rest(s2, c_tree_expr, res)) return false;
    source = s2;
    return true;
  }
  while (statements.length) {
    auto stmt = statements.take(), start = stmt;
    // logln("> ", stmt.replace("\n", "\\"));
    stmt.accept("__extension__");
    if (stmt.accept("#define")) {
      if (stmt.accept("__")) continue; // internal
      string id;
      Expr ex;
      if (!stmt.gotIdentifier(id)) goto giveUp;
      if (!stmt.strip().length) continue; // ignore this kind of #define.
      // logln("parse expr ", stmt, "; id '", id, "'");
      auto backup = stmt;
      if (!gotIntExpr(stmt, ex) || stmt.strip().length) {
        stmt = backup;
        bool isMacroParams(string s) {
          if (!s.accept("(")) return false;
          while (true) {
            string id;
            if (!s.gotIdentifier(id) || !s.accept(",")) break;
          }
          if (!s.accept(")")) return false;
          return true;
        }
        if (isMacroParams(stmt)) goto giveUp;
        // logln("full-parse ", stmt, " | ", start);
        // muahaha
        try {
          try {
            if (!readCExpr(stmt, &ex) || stmt.strip().length) {
              goto alternative;
            }
          } catch (Exception ex)
            goto alternative;
          if (false) {
            alternative:
            if (!readCExpr(stmt, &ex))
              goto giveUp;
          }
        } catch (Exception ex)
          goto giveUp; // On Error Fuck You
      }
      auto ea = new ExprAlias(ex, id);
      // logln("got ", ea);
      add(id, ea);
      continue;
    }
    bool isTypedef;
    if (stmt.accept("typedef")) isTypedef = true;
    if (stmt.accept("enum")) {
      auto entries = stmt.between("{", "}").split(",");
      Expr cur = mkInt(0);
      Named[] elems;
      foreach (entry; entries) {
        // logln("> ", entry);
        string id;
        if (!gotIdentifier(entry, id)) {
          stmt = entry;
          goto giveUp;
        }
        if (entry.accept("=")) {
          Expr ex;
          if (!readCExpr(entry, &ex) || entry.strip().length) {
            // logln("--", entry);
            goto giveUp;
          }
          cur = foldex(ex);
        }
        elems ~= new ExprAlias(cur, id);
        cur = foldex(lookupOp("+", cur, mkInt(1)));
      }
      // logln("Got from enum: ", elems);
      stmt = stmt.between("}", "");
      string name;
      if (stmt.strip().length && (!gotIdentifier(stmt, name) || stmt.strip().length)) {
        // logln("fail on '", stmt, "'");
        goto giveUp;
      }
      foreach (elem; elems) add(elem.getIdentifier(), elem);
      if (name)
        add(name, new TypeAlias(Single!(SysInt), name));
      continue;
    }
    bool isUnion;
    auto st2 = stmt;
    if (st2.accept("struct") || (st2.accept("union") && (isUnion = true, true))) {
      string ident;
      gotIdentifier(st2, ident);
      if (st2.accept("{")) {
        auto startstr = st2;
        auto st = new Structure(ident);
        st.isUnion = isUnion;
        while (true) {
          if (st2.startsWith("#define"))
            goto skip;
          auto ty = matchType(st2);
          // logln("match type @", st2, " = ", ty);
          if (!ty) goto giveUp1;
          while (true) {
            auto pos = st2.find("sizeof");
            if (pos == -1) break;
            auto block = st2[pos .. $].between("(", ")");
            auto sty = matchType(block);
            if (!sty) {
              goto giveUp1;
            }
            auto translated = Format(sty.size);
            st2 = st2[0 .. pos] ~ translated ~ st2[pos .. $].between(")", "");
            // logln("st2 => ", st2);
          }
          string name3;
          auto st3 = st2;
          Expr size;
          st3 = st3.replace("(int)", ""); // hax
          if (gotIdentifier(st3, name3) && st3.accept("[") && readCExpr(st3, &size) && st3.accept("]")) {
            redo:
            size = foldex(size);
            if (fastcast!(AstTuple)~ size.valueType()) {
              // unwrap "(foo)"
              size = (fastcast!(StructLiteral)~ (fastcast!(RCE)~ size).from)
                .exprs[$-1];
              goto redo;
            }
            auto ie = fastcast!(IntExpr)~ size;
            // logln("size: ", size);
            if (!ie) goto giveUp1;
            new RelMember(name3, new StaticArray(ty, ie.num), st);
            // logln("rest: ", st3);
            if (st3.strip().length) {
              goto giveUp1;
            }
            goto skip;
          }
          // logln(">> ", st2);
          if (st2.find("(") != -1) {
            // alias to void for now.
            add(ident, new TypeAlias(Single!(Void), ident));
            goto giveUp1; // can't handle yet
          }
          foreach (var; st2.split(",")) {
            if (ty == Single!(Void)) goto giveUp1;
            new RelMember(var.strip(), ty, st);
          }
        skip:
          st2 = statements.take();
          if (st2.accept("}")) break;
        }
        auto name = st2.strip();
        if (!name.length) name = ident;
        if (!st.name.length) st.name = name;
        add(name, st);
        continue;
        giveUp1:
        while (true) {
          // logln("stmt: ", st2, " in ", startstr);
          st2 = statements.take();
          if (st2.accept("}")) break;
        }
        // logln(">>> ", st2);
        continue;
      }
    }
    if (isTypedef) {
      auto target = matchType(stmt);
      string name;
      if (!target) goto giveUp;
      if (stmt.accept("{")) {
        while (true) {
          stmt = statements.take();
          if (stmt.accept("}")) break;
        }
      }
      if (!gotIdentifier(stmt, name)) goto giveUp;
      string typename = name;
      if (matchSimpleType(typename) && !typename.strip().length) {
        // logln("Skip type ", name, " for duplicate. ");
        continue;
      }
      Expr size;
      redo2:
      auto st3 = stmt;
      if (st3.accept("[") && readCExpr(st3, &size) && st3.accept("]")) {
        redo3:
        size = foldex(size);
        // unwrap "(bar)" again
        if (fastcast!(AstTuple)~ size.valueType()) {
          size = (fastcast!(StructLiteral)~ (fastcast!(RCE)~ size).from).exprs[$-1];
          goto redo3;
        }
        if (!fastcast!(IntExpr) (size)) goto giveUp;
        target = new StaticArray(target, (fastcast!(IntExpr)~ size).num);
        stmt = st3;
        goto redo2;
      }
      if (stmt.accept("[")) goto giveUp;
      auto ta = new TypeAlias(target, name);
      cache[name] = ta;
      continue;
    }
    
    stmt.accept("extern");
    stmt = stmt.strip();
    if (auto rest = stmt.startsWith("__attribute__")) stmt = rest.between(") ", "");
    
    if (auto ret = stmt.matchType()) {
      string name;
      if (!gotIdentifier(stmt, name) || !stmt.accept("("))
        goto giveUp;
      IType[] args;
      while (true) {
        if (auto ty = matchParam(stmt)) args ~= ty;
        else break;
      }
      if (!stmt.accept(")")) goto giveUp;
      if (args.length == 1 && args[0] == Single!(Void))
        args = null; // C is stupid.
      foreach (ref arg; args)
        if (resolveType(arg) == Single!(Short))
          arg = Single!(SysInt);
      auto fun = new Function;
      fun.name = name;
      fun.extern_c = true;
      fun.type = new FunctionType;
      fun.type.ret = ret;
      fun.type.params = args /map/ (IType it) { return Argument(it); };
      fun.sup = null;
      add(name, fun);
      continue;
    }
    giveUp:;
    // logln("Gave up on |", stmt, "| ", start);
  }
  auto ns = myNS.sup;
  foreach (key, value; cache) {
    if (ns.lookup(key)) {
      // logln("Skip ", key, " as duplicate. ");
      continue;
    }
    // logln("Add ", value);
    ns.add(key, value);
  }
  logSmart!(false)("# Got ", cache.length, " definitions from ", filename, " in ", sec() - start_time, "s. ");
}

import ast.fold, ast.literal_string;
Object gotCImport(ref string text, ParseCb cont, ParseCb rest) {
  if (!text.accept("c_include")) return null;
  Expr ex;
  if (!rest(text, "tree.expr", &ex))
    text.failparse("Couldn't find c_import string expr");
  if (!text.accept(";")) text.failparse("Missing trailing semicolon");
  auto str = fastcast!(StringExpr)~ foldex(ex);
  if (!str)
    text.failparse(foldex(ex), " is not a string");
  auto name = str.str;
  // prevent injection attacks
  foreach (ch; name)
    if (!(ch in Range['a'..'z'].endIncl)
      &&!(ch in Range['A'..'Z'].endIncl)
      &&!(ch in Range['0' .. '9'].endIncl)
      &&("/_-.".find(ch) == -1)
    )
      throw new Exception("Invalid character in "~name~": "~ch~"!");
  // prevent snooping
  if (name.find("..") != -1)
    throw new Exception("Can't use .. in "~name~"!");
  
  string filename;
  if (name.exists()) filename = name;
  else {
    foreach (path; include_path) {
      auto combined = path.sub(name);
      if (combined.exists()) { filename = combined; break; }
    }
  }
  if (!filename) throw new Exception("Couldn't find "~name~"!");
  auto cmdline = 
    "gcc -pthread -m32 -Xpreprocessor -dD -E "
    ~ (include_path
      /map/ (string s) { return "-I"~s; }
      ).join(" ")
    ~ " " ~ filename;
  // logln("? ", cmdline);
  auto src = readback(cmdline);
  parseHeader(filename, src, rest);
  return Single!(NoOp);
}
mixin DefaultParser!(gotCImport, "tree.toplevel.c_import");
