module ast.structure;

import ast.types, ast.base, ast.namespace, ast.vardecl,
  ast.static_arrays, ast.int_literal, parseBase;

import tools.base: ex, This, This_fn, rmSpace, join;
int sum(S, T)(S s, T t) {
  int res;
  foreach (entry; s)
    res += t(entry);
  return res;
}

// next power of two
int np2(int i) {
  int p = 1;
  while (p < i) p *= 2;
  return p;
}

int needsAlignmentStruct(Structure st) {
  int al = 1;
  st.select((string s, RelMember rm) {
    auto ta = needsAlignment(rm.type);
    if (ta > al) al = ta;
  }, &st.rmcache);
  return al;
}

import tools.log;
class RelMember : Expr, Named, RelTransformable {
  string name;
  IType type;
  int index;
  string makeOffset(Structure base) {
    auto type = base.llvmType();
    return qformat("ptrtoint(", this.type.llvmType(), "* getelementptr(", type, "* null, i32 0, i32 ", index, ") to i32)");
  }
  override {
    string toString() { return Format("["[], name, ": "[], type, " @"[], index, "]"[]); }
    IType valueType() { return type; }
    void emitLLVM(LLVMFile lf) {
      logln("Untransformed rel member "[], this, ": cannot emit. "[]);
      fail;
    }
    mixin defaultIterate!();
    string getIdentifier() { return name; }
    Object transform(Expr base) {
      return fastcast!(Object) (mkMemberAccess(base, name));
    }
  }
  this(string name, IType type, int index) {
    this.name = name;
    this.type = type;
    this.index = index;
  }
  this(string name, IType type, Namespace ns) {
    this(name, type, 0);
    auto sl = fastcast!(StructLike)~ ns;
    
    string stname;
    if (sl) {
      if (sl.immutableNow)
        throw new Exception(Format("Cannot add "[], this, " to "[], sl, ": size already fixed. "[]));
      index = sl.numMembers();
      stname = sl.getIdentifier();
    } else {
      todo(qformat("unno how to add rel member to ", ns));
    }
    
    // alignment
    bool isAligned = true;
    if (sl && sl.isPacked) isAligned = false;
    
    /*if (isAligned) {
      doAlign(offset, type);
      if (st && st.minAlign > 1) offset = roundTo(offset, st.minAlign);
    }*/
    if (!this.name) this.name = qformat("_anon_struct_member_"[], sl.numMembers(), "_of_"[], type.mangle());
    ns.add(this);
  }
  override RelMember dup() { return this; }
}

class RelMemberLV : RelMember, LValue {
  void emitLocation(LLVMFile lf) {
    logln("Untransformed rel member "[], this, ": cannot emit location. "[]);
    fail;
  }
  RelMemberLV dup() { return new RelMemberLV(name, type, index); }
  this(string name, IType type, int index) { super(name, type, index); }
  this(string name, IType type, Namespace ns) { super(name, type, ns); }
}

extern(C) Expr _make_tupleof(Structure str, Expr ex);
final class Structure : Namespace, RelNamespace, IType, Named, hasRefType, Importer, SelfAdding, StructLike, ExternAware {
  static const isFinal = true;
  mixin TypeDefaults!(false);
  string name;
  bool isUnion, packed, isTempStruct;
  /*
    This indicates that we've accessed the struct size.
    Consequentially, it is now cast in lead and may no
    longer be changed by adding new members.
    This prevents the following case:
    struct A { int foo; A meep() { A res; int bogus = 17; return res; } int bar; }
    where the assignment to bogus, combined with the retroactive size change of A,
    overwrites the previously-unknown int bar in meep.
  */
  bool isImmutableNow;
  int cached_length, cached_size;
  string cached_llvm_type, cached_llvm_size;
  mixin ImporterImpl!();
  NSCache!(string, RelMember) rmcache;
  string offsetOfNext(IType it) {
    int len;
    string strtype;
    void append(string ty) {
      len ++;
      if (strtype) strtype ~= ", ";
      strtype ~= ty;
    }
    structDecompose(typeToLLVM(this), &append);
    auto thingy = typeToLLVM(it);
    append(thingy);
    strtype = "{"~strtype~"}";
    return lloffset(strtype, thingy, len-1);
  }
  void markExternC() {
    foreach (entry; field) {
      auto obj = entry._1;
      if (auto ex = fastcast!(Expr)(obj)) obj = fastcast!(Object)(ex.valueType());
      if (auto eat = fastcast!(ExternAware)(obj))
        eat.markExternC();
    }
  }
  bool addsSelf() { return true; }
  bool isPointerLess() {
    bool pointerless = true;
    select((string, RelMember member) { pointerless &= member.type.isPointerLess(); });
    return pointerless;
  }
  bool isComplete() {
    bool complete = true;
    select((string, RelMember member) { complete &= member.type.isComplete(); });
    return complete;
  }
  bool immutableNow() { return isImmutableNow; }
  bool isPacked() { return packed; }
  string llvmType() {
    if (!cached_llvm_type) {
      if (isUnion) {
        auto sz = llvmSize();
        cached_llvm_type = qformat("[", sz, " x i8]");
      } else {
        string list;
        select((string, RelMember member) {
          if (list.length && member.index == 0) return; // freak of nature
          if (list.length) list ~= ", ";
          list ~= typeToLLVM(member.type, true);
        });
        cached_llvm_type = qformat("{", list, "}");
      }
    }
    return cached_llvm_type;
  }
  string llvmSize() {
    if (cached_llvm_size) return cached_llvm_size;
    {
      int num;
      string size;
      select((string, RelMember member) { num++; if (num == 1) size = member.type.llvmSize(); });
      if (num == 1) return size;
    }
    if (isUnion) {
      string len = "0";
      select((string, RelMember member) {
        len = llmax(len, member.type.llvmSize());
      });
      // logln("Structure::llvmSize for union ", this.name, " (oh noo): ", len.length);
      return len;
    }
    {
      int count;
      string size;
      bool sameSize = true;
      select((string, RelMember member) {
        auto msize = member.type.llvmSize();
        if (!sameSize || !size || msize != size) {
          if (!size) { size = msize; count = 1; }
          else {
            // hax
            if (member.name != "self") sameSize = false;
          }
        }
        else count++;
      });
      if (size && sameSize) return llmul(qformat(count), size);
    }
    auto ty = llvmType();
    cached_llvm_size = readllex(qformat("ptrtoint(", ty, "* getelementptr(", ty, "* null, i32 1) to i32)"));
    return cached_llvm_size;
  }
  Structure dup() {
    auto res = fastalloc!(Structure)(name);
    res.sup = sup;
    res.field = field.dup;
    res.rebuildCache();
    res.isUnion = isUnion; res.packed = packed; res.isTempStruct = isTempStruct;
    res.isImmutableNow = isImmutableNow;
    res.cached_length = cached_length; res.cached_size = cached_size;
    res.cached_llvm_type = cached_llvm_type;
    res.cached_llvm_size = cached_llvm_size;
    return res;
  }
  int numMembers() {
    int res;
    select((string, RelMember member) { res++; }, &rmcache);
    return res;
  }
  int length() {
    isImmutableNow = true;
    if (field.length == cached_length)
      if (cached_size) return cached_size;
    auto res = numMembers();
	// auto pre = res;
    // doAlign(res, this);
    // if (res != pre) logln(pre, " -> "[], res, ": "[], this);
    cached_size = res;
    cached_length = field.length;
    return res;
  }
  RelMember selectMember(int offs) {
    int i;
    RelMember res;
    select((string, RelMember member) { if (i++ == offs) res = member; }, &rmcache);
    return res;
  }
  RelMember[] members() { return selectMap!(RelMember, "$"[]); }
  Structure slice(int from, int to) {
    assert(!isUnion);
    auto res = fastalloc!(Structure)(cast(string) null);
    res.packed = packed;
    res.sup = sup;
    int i;
    select((string, RelMember member) { if (i !< from && i < to) fastalloc!(RelMember)(member.name, member.type, res); i++; }, &rmcache);
    return res;
  }
  NSCache!(string) namecache;
  NSCache!(IType) typecache;
  string[] names() { return selectMap!(RelMember, "$.name"[])(&namecache); }
  IType[] types() { return selectMap!(RelMember, "$.type"[])(&typecache); }
  int minAlign = 1; // minimal alignment for struct members (4 for C structs)
  this(string name) {
    this.name = name;
  }
  string manglecache;
  string mangle() {
    if (!manglecache) {
      string ersatzname = qformat("struct_"[], name.cleanup());
      if (!name) {
        ersatzname = "anon_struct";
        select((string, RelMember member) { ersatzname = qformat(ersatzname, "_", member.type.mangle, "_", member.name); }, &rmcache);
      }
      if (sup) manglecache = mangle(ersatzname, null);
      else manglecache = ersatzname;
    }
    return manglecache;
  }
  IType getRefType() { return fastalloc!(Pointer)(this); }
  string getIdentifier() { return name; }
  string mangle(string name, IType type) {
    string type_mangle;
    if (type) type_mangle = type.mangle() ~ "_";
    return sup.mangle(name, null)~"_"~type_mangle~name;
  }
  Object lookupRel(string str, Expr base, bool isDirectLookup = true) {
    if (str == "tupleof") {
      return fastcast!(Object) (_make_tupleof(this, base));
    }
    auto res = lookup(str, true);
    if (auto rt = fastcast!(RelTransformable) (res))
      return fastcast!(Object) (rt.transform(base));
    return res;
  }
  // Let two structs be equal if their names and sizes are equal
  // and all their members are of the same size
  int opEquals(IType it) {
    auto str = fastcast!(Structure)~ it;
    if (!str) return false;
    if (str is this) return true;
    if (str.mangle() != mangle()) return false;
    if (str.length != length) return false;
    auto n1 = str.names(), n2 = names();
    if (n1.length != n2.length) return false;
    foreach (i, n; n1) if (n != n2[i]) return false;
    auto t1 = str.types(), t2 = types();
    foreach (i, v; t1) if (v.llvmType() != t2[i].llvmType()) return false;
    return true;
  }
  string toString() {
    if (!name) {
      string[] names;
      foreach (elem; field)
        if (auto n = fastcast!(Named) (elem._1)) {
          string id = n.getIdentifier();
          if (auto rm = fastcast!(RelMember) (elem._1))
            // id = Format(id, "<"[], rm.valueType().llvmType(), ">@"[], rm.index);
            id = Format(id, "<"[], rm.valueType(), ">@"[], rm.index);
          names ~= id;
        }
      return Format("{struct "[], names.join(", "[]), "}"[]);
    }
    if (auto mn = get!(ModifiesName)) return mn.modify(name);
    return name;
  }
  bool isTempNamespace() { return isTempStruct; }
  void __add(string name, Object obj) {
    cached_llvm_type = null;
    cached_llvm_size = null;
    auto ex = fastcast!(Expr) (obj);
    if (ex && fastcast!(Variadic) (ex.valueType())) throw new Exception("Variadic tuple: Wtf is wrong with you. "[]);
    super.__add(name, obj);
  }
}

import ast.modules;
bool matchStructBodySegment(ref string text, Namespace ns,
                     ParseCb* rest = null, bool alwaysReference = false, bool matchMany = true) {
  auto backup = namespace();
  namespace.set(ns);
  scope(exit) namespace.set(backup);
  
  Named smem;
  string t2;
  string[] names; IType[] types;
  string strname; IType strtype;
  
  Object match(ref string text, string rule) {
    if (rest) { Object res; if (!(*rest)(text, rule, &res)) return null; return res; }
    else {
      return parse(text, rule);
    }
  }
  
  bool expr() {
    auto backup = text;
    if (test(smem = fastcast!(Named)(match(text, "struct_member")))) {
      if (!addsSelf(smem)) ns.add(smem);
      return true;
    }
    text = backup;
    if (test(strtype = fastcast!(IType) (match(text, "type")))
      && text.bjoin(
        text.gotIdentifier(strname),
        text.accept(","[]),
        { names ~= strname; types ~= strtype; }
      ) && text.accept(";"[])) {
      foreach (i, strname; names)
        fastalloc!(RelMemberLV)(strname, types[i], ns);
      names = null; types = null;
      return true;
    }
    text = backup;
    return false;
  }
  
  if (matchMany) return text.many(expr());
  else return expr();
}

// so templates can mark us as weak
class NoOpMangleHack : Statement, IsMangled {
  Structure sup;
  this(Structure s) { sup = s; }
  NoOpMangleHack dup() { return this; }
  override void emitLLVM(LLVMFile lf) { }
  mixin defaultIterate!();
  override string mangleSelf() { return sup.mangle(); }
  override void markWeak() {
    foreach (entry; sup.field)
      if (auto mg = fastcast!(IsMangled)(entry._1)) mg.markWeak();
  }
  override void markExternC() {
    sup.markExternC();
  }
}

Object gotStructDef(bool returnIt)(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  bool isUnion;
  if (!t2.accept("struct"[])) {
    if (!t2.accept("union"[]))
      return null;
    isUnion = true;
  }
  string name;
  Structure st;
  if (t2.gotIdentifier(name) && t2.accept("{"[])) {
    New(st, name);
    st.isUnion = isUnion;
    
    auto ns = namespace();
    ns.add(st);
    while (fastcast!(Structure) (ns)) ns = ns.sup;
    st.sup = ns; // implicitly static
    
    auto rtptbackup = RefToParentType();
    scope(exit) RefToParentType.set(rtptbackup);
    RefToParentType.set(fastalloc!(Pointer)(st));
    
    auto rtpmbackup = *RefToParentModify();
    scope(exit) *RefToParentModify.ptr() = rtpmbackup;
    *RefToParentModify.ptr() = delegate Expr(Expr baseref) {
      return fastalloc!(DerefExpr)(baseref);
    };
    
    if (matchStructBodySegment(t2, st, &rest)) {
      if (!t2.accept("}"[]))
        t2.failparse("Missing closing struct bracket"[]);
      text = t2;
      static if (returnIt) return st;
      else return fastalloc!(NoOpMangleHack)(st);
    } else {
      t2.failparse("Couldn't match structure body"[]);
    }
  } else return null;
}
mixin DefaultParser!(gotStructDef!(false), "tree.typedef.struct"[]);
mixin DefaultParser!(gotStructDef!(false), "tree.stmt.typedef_struct"[], "32"[]);
mixin DefaultParser!(gotStructDef!(true), "struct_member.struct"[]);

class StructLiteral : Expr {
  Structure st;
  Expr[] exprs;
  this(Structure st, Expr[] exprs) {
    this.st = st;
    foreach (ex; exprs) if (!ex) fail;
    this.exprs = exprs.dup;
  }
  private this() { }
  mixin defaultIterate!(exprs);
  override {
    string toString() { return Format("literal "[], st, " {"[], exprs, "}"[]); }
    StructLiteral dup() {
      auto res = new StructLiteral;
      res.st = st;
      res.exprs = exprs.dup;
      foreach (ref entry; res.exprs) entry = entry.dup;
      return res;
    }
    IType valueType() { return st; }
    void emitLLVM(LLVMFile lf) {
      auto parts = new string[exprs.length*2];
      // logln("slit ", exprs);
      // fill in reverse to conform with previous fcc's behavior
      foreach_reverse (i, ex; exprs) {
        auto ta = typeToLLVM(ex.valueType()), tb = typeToLLVM(ex.valueType(), true);
        if (ta == tb) {
          parts[i*2] = ta;
          parts[i*2+1] = save(lf, ex);
        } else {
          parts[i*2] = tb;
          llcast(lf, ta, tb, save(lf, ex));
          parts[i*2+1] = lf.pop();
        }
      }
      formTuple(lf, parts);
    }
  }
}

import ast.pointer;
class MemberAccess_Expr : Expr, HasInfo {
  Expr base;
  RelMember stm;
  string name;
  /// intended as part of a set of accesses that will access every member of a struct.
  /// if true, we can optimize each individual access while assuming that side effects won't get lost.
  bool intendedForSplit;
  int counter;
  static int mae_counter;
  this() {
    counter = mae_counter ++;
    // if (counter == 2017) fail;
  }
  this(Expr base, string name) {
    this.base = base;
    this.name = name;
    this();
    auto ns = fastcast!(Namespace) (base.valueType());
    if (!ns) { logln("Base is not NS-typed: "[], base.valueType(), " being ", base); fail; }
    stm = fastcast!(RelMember) (ns.lookup(name));
    if (!stm) {
      logln("No member '"[], name, "' in "[], base.valueType(), "!"[]);
      fail;
    }
  }
  string getInfo() { return "."~name; }
  MemberAccess_Expr create() { return new MemberAccess_Expr; }
  MemberAccess_Expr dup() {
    auto res = create();
    res.base = base.dup;
    res.stm = stm.dup;
    res.name = name;
    return res;
  }
  mixin defaultIterate!(base);
  override {
    import tools.log;
    string toString() {
      return qformat(counter, " ("[], base, "[])."[], name);
    }
    IType valueType() { return stm.type; }
    import tools.base;
    void emitLLVM(LLVMFile lf) {
      auto bvt = base.valueType();
      auto bs = typeToLLVM(bvt);
      auto src = save(lf, base);
      if (fastcast!(Structure)(bvt).isUnion) {
        auto mt = typeToLLVM(stm.type);
        auto tmp = alloca(lf, "1", bs);
        put(lf, "store ", bs, " ", src, ", ", bs, "* ", tmp);
        load(lf, "load ", mt, "* ", bitcastptr(lf, bs, mt, tmp));
        return;
      }
      // put(lf, "; mae ", this);
      // put(lf, "; to ", stm, " into ", typeToLLVM(bvt), " (", bvt, ")");
      // don't want to fall over and die if user code has a variable called "self"
      // if (name == "self") fail; // ast.vector done a baad baad thing
      auto ex = save(lf, "extractvalue ", typeToLLVM(bvt), " ", src, ", ", stm.index);
      auto from = typeToLLVM(stm.type, true), to = typeToLLVM(stm.type);
      if (from == to) { push(lf, ex); }
      else { llcast(lf, from, to, ex); }
    }
  }
}

class MemberAccess_LValue_ : MemberAccess_Expr, LValue {
  int id;
  this(LValue base, string name) {
    super(fastcast!(Expr)~ base, name);
  }
  this() { }
  override {
    MemberAccess_LValue_ create() { return new MemberAccess_LValue_; }
    MemberAccess_LValue_ dup() { return fastcast!(MemberAccess_LValue_) (super.dup()); }
    void emitLocation(LLVMFile lf) {
      (fastcast!(LValue)(base)).emitLocation(lf);
      auto ls = lf.pop();
      if (fastcast!(Structure)(base.valueType()).isUnion) {
        auto mt = typeToLLVM(stm.type);
        push(lf, bitcastptr(lf, typeToLLVM(base.valueType()), mt, ls));
        return;
      }
      load(lf, "getelementptr inbounds ", typeToLLVM(base.valueType()), "* ", ls, ", i32 0, i32 ", stm.index);
      auto restype = stm.type;
      auto from = typeToLLVM(restype, true)~"*", to = typeToLLVM(restype)~"*";
      // logln(lf.count, ": emitLocation of mal to ", base.valueType(), ", from ", from, ", to ", to);
      if (from != to) {
        llcast(lf, from, to, lf.pop(), qformat(nativePtrSize));
      }
    }
  }
}

final class MemberAccess_LValue : MemberAccess_LValue_ {
  static const isFinal = true;
  this(LValue base, string name) { super(base, name); }
  this() { super(); }
}

import ast.fold, ast.casting;
static this() {
  foldopt ~= delegate Itr(Itr it) {
    if (auto r = fastcast!(RCE) (it)) {
      if (auto lit = fastcast!(StructLiteral)~ r.from) {
        if (lit.exprs.length == 1) {
          if (lit.exprs[0].valueType() == r.to)
            return fastcast!(Itr) (lit.exprs[0]); // pointless keeping a cast
          return reinterpret_cast(r.to, lit.exprs[0]);
        }
      }
    }
    return null;
  };
  foldopt ~= delegate Itr(Itr it) {
    if (auto mae = fastcast!(MemberAccess_Expr) (it)) {
      auto base = mae.base;
      auto basebackup = base;
      bool deb;
      /*if (mae.stm.name == "self") {
        deb = true;
      }*/
      if (deb) logln("deb on");
      if (mae.stm.type.llvmType() == base.valueType().llvmType()) {
        if (deb) logln("deb early direct-match for ", mae, " => ", base);
        return fastcast!(Iterable) (foldex(reinterpret_cast(mae.stm.type, base)));
      }
      
      Structure st;
      if (auto rce = fastcast!(RCE)~ base) {
        base = rce.from;
        st = fastcast!(Structure)~ rce.to;
      }
      
      if (base.valueType() == mae.stm.type) {
        if (deb) logln("deb direct-match for ", mae, " => ", base);
        return base;
      }
      if (st && st.length == 1) {
        if (deb) logln("deb foldopt cast ", st, " TO ", mae.stm.type);
        return reinterpret_cast(mae.stm.type, base);
      }
      {
        if (deb) {
          logln("deb bvt = ", base.valueType());
          logln("being ", base.valueType().llvmSize());
          logln("  and ", mae.stm.type.llvmSize());
        }
        auto sx = fastcast!(Structure)(base.valueType());
        if (sx && sx.llvmSize() == mae.stm.type.llvmSize()) { // close enough
          return reinterpret_cast(mae.stm.type, base);
        }
      }
      if (deb) {
        logln("deb with ", mae.stm, " into ", st);
        logln("deb BASE = ", fastcast!(Object)(base).classinfo.name, " ", base);
      }
      if (auto sl = fastcast!(StructLiteral)~ base) {
        /*foreach (expr; sl.exprs) {
          logln("  ", expr);
        }*/
        if (!mae.intendedForSplit && sl.exprs.length > 1) {
          bool cheap = true;
          foreach (ref ex; sl.exprs) {
            // if it was for multiple access, it'd already have checked for that separately
            if (!_is_cheap(ex, CheapMode.Flatten)) {
              // logln("not cheap: "[], ex);
              cheap = false;
              break;
            }
          }
          if (!cheap) return null; // may be side effects of other expressions in the SL
        }
        Expr res;
        int i;
        if (!st)
          st = fastcast!(Structure)~ base.valueType();
        else {
          // TODO: assert: struct member offsets identical!
        }
        if (st) st.select((string, RelMember member) {
          if (member.type == mae.stm.type && member.index == mae.stm.index && mae.valueType() == sl.exprs[i].valueType()) {
            res = sl.exprs[i];
          }
          i++;
        }, &st.rmcache);
        // logln(" => ", res);
        if (auto it = fastcast!(Iterable) (res))
          return it;
      }
    }
    return null;
  };
  alignChecks ~= (IType it) {
    if (auto st = fastcast!(Structure) (it)) {
      return needsAlignmentStruct(st);
    }
    return 0;
  };
}

Expr mkMemberAccess(Expr strct, string name) {
  if(auto lv=fastcast!(LValue)(strct)) return fastalloc!(MemberAccess_LValue)(lv, name);
  else                                 return fastalloc!(MemberAccess_Expr  )(strct, name);
}

pragma(set_attribute, C_mkMemberAccess, externally_visible);
extern(C) Expr C_mkMemberAccess(Expr strct, string name) { return mkMemberAccess(strct, name); }

Expr depointer(Expr ex) {
  while (true) {
    if (auto ptr = fastcast!(Pointer) (resolveType(ex.valueType()))) {
      ex = fastalloc!(DerefExpr)(ex);
    } else break;
  }
  return ex;
}

extern(C) bool _isITemplate(Object obj);

import ast.parse, ast.fun, tools.base: or;
Object gotMemberExpr(ref string text, ParseCb cont, ParseCb rest) {
  assert(lhs_partial());
  auto first_ex = fastcast!(Expr)~ lhs_partial();
  auto t2 = text;
  string member;
  if (!t2.gotIdentifier(member)) return null;
  
  Expr[] alts;
  IType[] spaces;
  if (first_ex) {
    Expr ex = first_ex;
    auto ex3 = ex;
    Expr[] cleanups;
    gotImplicitCast(ex3, (Expr ex) {
      auto vt = ex.valueType();
      if (auto srn = fastcast!(SemiRelNamespace) (vt))
        vt = fastcast!(IType) (srn.resolve());
      if (auto rn = fastcast!(RelNamespace) (vt)) {
        own_append(alts, ex);
        own_append(spaces, vt);
      } else own_append(cleanups, ex);
      return false;
    }, false);
    foreach (c; cleanups) cleanupex(c, true);
    cleanups = null;
    
    ex3 = ex;
    gotImplicitCast(ex3, (Expr ex) {
      auto ex4 = depointer(ex);
      if (ex4 !is ex) {
        gotImplicitCast(ex4, (Expr ex) {
          auto vt = ex.valueType();
          if (auto srn = fastcast!(SemiRelNamespace) (vt))
            vt = fastcast!(IType) (srn.resolve());
          if (auto rn = fastcast!(RelNamespace) (vt)) {
            own_append(alts, ex);
            own_append(spaces, vt);
          } else own_append(cleanups, ex);
          return false;
        }, false);
      } else own_append(cleanups, ex);
      return false;
    }, false);
    foreach (c; cleanups) cleanupex(c, true);
    cleanups = null;
    
  } else {
    if (auto ty = fastcast!(IType) (lhs_partial())) {
      auto vt = resolveType(ty);
      if (auto srn = fastcast!(SemiRelNamespace) (vt))
        vt = fastcast!(IType) (srn.resolve());
      
      if (fastcast!(Namespace) (vt) || fastcast!(RelNamespace) (vt)) {
        own_append(alts, cast(Expr) null);
        own_append(spaces, vt);
      }
    }
  }
  if (!alts.length) {
    return null;
  }
  
  auto backupmember = member;
  auto backupt2 = t2;
  Expr ex;
try_next_alt:
  member = backupmember; // retry from start again
  t2 = backupt2;
  if (!alts.length) {
    return null;
  }
  
  if (ex) if (auto tmp = fastcast!(Temporary)(ex)) tmp.cleanup(true);
  
  ex = alts[0]; alts = alts[1 .. $];
  auto space = spaces[0]; spaces = spaces[1 .. $];
  
  auto pre_ex = ex;
  
  auto rn = fastcast!(RelNamespace) (space);
retry:
  auto ns = fastcast!(Namespace) (space);
  if (!ex || !rn) {
    Object m;
    if (ns) m = ns.lookup(member, true);
    if (!m && rn) m = rn.lookupRel(member, null);
    if (!m) goto try_next_alt;
    
    // auto ex2 = fastcast!(Expr) (m);
    // if (!ex2) {
    // what
    /*if (!m) {
      if (t2.eatDash(member)) { logln("1 Reject "[], member, ": no match"[]); goto retry; }
      text.setError(Format("No "[], member, " in "[], ns, "!"[]));
      goto try_next_alt;
    }*/
    
    text = t2;
    return m;
  }
  auto m = rn.lookupRel(member, ex);
  if (!m) {
    if (t2.eatDash(member)) { goto retry; }
    string mesg, name;
    /*auto info = Format(pre_ex.valueType());
    if (info.length > 64) info = info[0..64] ~ " [snip]";
    if (auto st = fastcast!(Structure) (resolveType(fastcast!(IType) (rn)))) {
      name = st.name;
      /*logln("alts1 "[]);
      foreach (i, alt; alts)
        logln("  "[], i, ": "[], alt);* /
      mesg = qformat(member, " is not a member of "[], info, ", containing "[], st.names);
    } else {
      /*logln("alts2: "[]);
      foreach (i, alt; alts)
        logln("  "[], i, ": "[], alt);* /
      mesg = qformat(member, " is not a member of non-struct "[], info);
    }
    text.setError(mesg);*/
    goto try_next_alt;
  }
  text = t2;
  return m;
}
mixin DefaultParser!(gotMemberExpr, "tree.rhs_partial.access_rel_member"[], null, "."[]);
