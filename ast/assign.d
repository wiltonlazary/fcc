module ast.assign;

import ast.base, ast.pointer;

class SelfAssignmentException : Exception {
  this() { super("self assignment detected"[]); }
}

extern(C) Tree fcc_assignment_collapse(Tree t);
class _Assignment(T) : LineNumberedStatementClass {
  T target;
  Expr value;
  bool blind;
  bool nontemporal;
  import tools.log;
  this(T t, Expr e, bool force = false, bool blind = false, bool nontemporal = false) {
    this.blind = blind;
    this.nontemporal = nontemporal;
    auto tvt = t.valueType(), evt = e.valueType();
    if (!force && resolveType(tvt) != resolveType(evt)) {
      logln("Can't assign: "[], t);
      logln(" of "[], t.valueType());
      logln(" <- "[], e.valueType());
      logln("(", resolveType(tvt), ", ", resolveType(evt), ")");
      breakpoint();
      throw new Exception(Format("Assignment type mismatch: cannot assign ", e.valueType(), " to ", t.valueType()));
    }
    target = t;
    value = e;
  }
  private this() { }
  mixin DefaultDup!();
  mixin defaultIterate!(target, value);
  Tree collapse() { return fcc_assignment_collapse(this); }
  override string toString() { return Format(target, " := "[], value, "; "[]); }
  override void emitLLVM(LLVMFile lf) {
    super.emitLLVM(lf);
    push(lf, save(lf, value));
    static if (is(T: MValue)) {
      target.emitAssignment(lf);
    } else {
      target.emitLocation(lf);
      auto dest = lf.pop(), src = lf.pop();
      if (value.valueType().llvmSize() != "0") {
        // use addrspace(1) to preserve null accesses so they can crash properly
        auto basetype = typeToLLVM(target.valueType());
        if (!lf.addrspace0) {
          auto usf = is_unsafe_fast(); // if this is true, don't use addrspace(1)
          splitstore(lf, typeToLLVM(value.valueType()), src, basetype, dest, usf?false:true, nontemporal);
          // string addrspacecast = "bitcast ";
          // if (llvmver() >= 34) addrspacecast = "addrspacecast ";
          // dest = save(lf, addrspacecast, basetype, "* ", dest, " to ", basetype, " addrspace(1)", "*");
          // put(lf, "store ", typeToLLVM(value.valueType()), " ", src, ", ", basetype, " addrspace(1)* ", dest);
        } else {
          splitstore(lf, typeToLLVM(value.valueType()), src, typeToLLVM(target.valueType()), dest, false, nontemporal);
          // put(lf, "store ", typeToLLVM(value.valueType()), " ", src, ", ", typeToLLVM(target.valueType()), "* ", dest);
        }
      }
    }
  }
}

alias _Assignment!(LValue) Assignment;
alias _Assignment!(MValue) AssignmentM;
import ast.casting, ast.fold;
Object gotAssignment(ref string text, ParseCb cont, ParseCb rest) {
  auto t2 = text;
  LValue lv; MValue mv;
  Expr ex;
  bool nontemporal;
  bool mayNontemp() {
    if (t2.accept("nontemporal")) nontemporal = true;
    return true;
  }
  if (rest(t2, "tree.expr _tree.expr.bin"[], &ex) && mayNontemp() && t2.accept("="[])) {
    Expr value;
    IType[] its;
    if (!rest(t2, "tree.expr"[], &value)) {
      t2.failparse("Could not parse assignment source"[]);
    }
    /*
    auto t3 = t2;
    if (t3.mystripl().length && !t3.acceptTerminatorSoft()) {
      t2.failparse("Unknown text after assignment! "[]);
    }
    */
    
    auto bexup = ex;
    bool thereWereAssignables;
    // don't comment in without documenting why!
    // opt(ex);
    if (!gotImplicitCast(ex, value.valueType(), (Expr ex) {
      // logln("can we assign our ", value.valueType(), " maybe to ", ex, "?");
      if (!fastcast!(LValue) (ex) && !fastcast!(MValue) (ex))
        return false;
      thereWereAssignables = true;
      
      auto ex2 = value;
      auto ev = ex.valueType();
      if (!gotImplicitCast(ex2, ev, (IType it) {
        return test(it == ev);
      })) return false;
      value = ex2;
      return true;
    })) {
      if (!thereWereAssignables) // this was never an assignment
        return null;
      // logln("Could not match "[], bexup.valueType(), " to "[], value.valueType());
      // logln("(note: "[], (fastcast!(Object) (bexup.valueType())).classinfo.name, ")"[]);
      // logln("(note 2: "[], bexup.valueType() == value.valueType(), ")"[]);
      // logln("btw backup ex is "[], (cast(Object) ex).classinfo.name, ": "[], ex);
      t2.failparse("Could not assign\n  ", value.valueType(), "\nto\n  ", bexup.valueType()/*, " (", value, ")"*/);
      // setError(t2, "Could not match "[], bexup.valueType(), " to "[], value.valueType());
      // return null;
      // t2.failparse("Parsing error"[]);
    }

    lv = fastcast!(LValue) (ex); mv = fastcast!(MValue) (ex);
    if (!lv && !mv) return null;
    
    Expr target;
    if (lv) target = lv;
    else target = mv;
    
    // logln(target.valueType(), " <- "[], value.valueType());
    LineNumberedStatementClass res;
    try {
      if (lv)
        res = fastalloc!(Assignment)(lv, value, false, false, nontemporal);
      else
        res = fastalloc!(AssignmentM)(mv, value, false, false, nontemporal);
    } catch (Exception ex) {
      text.failparse(ex);
    }
    res.configPosition(text);
    text = t2;
    return res;
  } else return null;
}
mixin DefaultParser!(gotAssignment, "tree.semicol_stmt.assign"[], "1"[]);

static this() {
  registerClass("ast.assign"[], new Assignment);
  registerClass("ast.assign"[], new AssignmentM);
}

Statement mkAssignment(Expr to, Expr from) {
  if (from is to) {
    throw new SelfAssignmentException;
  }
  if (auto lv = fastcast!(LValue) (to)) return fastalloc!(Assignment)(lv, from);
  if (auto mv = fastcast!(MValue) (to)) return fastalloc!(AssignmentM)(mv, from);
  logln("Invalid target for assignment: "[], to);
  fail;
}

void emitAssign(LLVMFile lf, LValue target, Expr source, bool force = false, bool blind = false) {
  scope as = new Assignment(target, source, force, blind);
  as.emitLLVM(lf);
}
