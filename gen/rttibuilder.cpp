#include "gen/llvm.h"

#include "aggregate.h"
#include "mtype.h"

#include "gen/arrays.h"
#include "gen/irstate.h"
#include "gen/linkage.h"
#include "gen/llvmhelpers.h"
#include "gen/rttibuilder.h"
#include "gen/tollvm.h"

#include "ir/irstruct.h"

TypeInfoBuilder::TypeInfoBuilder(ClassDeclaration* base_class)
{
    // make sure the base typeinfo class has been processed
    base_class->codegen(Type::sir);

    base = base_class;
    basetype = (TypeClass*)base->type;

    baseir = base->ir.irStruct;
    assert(baseir && "no IrStruct for TypeInfo base class");

    // just start with adding the vtbl
    inits.push_back(baseir->getVtblSymbol());
    // and monitor
    push_null_vp();
}

void TypeInfoBuilder::push(llvm::Constant* C)
{
    inits.push_back(C);
}

void TypeInfoBuilder::push_null_vp()
{
    inits.push_back(getNullValue(getVoidPtrType()));
}

void TypeInfoBuilder::push_typeinfo(Type* t)
{
    inits.push_back(DtoTypeInfoOf(t, true));
}

void TypeInfoBuilder::push_classinfo(ClassDeclaration* cd)
{
    inits.push_back(cd->ir.irStruct->getClassInfoSymbol());
}

void TypeInfoBuilder::push_string(const char* str)
{
    inits.push_back(DtoConstString(str));
}

void TypeInfoBuilder::push_null_void_array()
{
    const llvm::Type* T = DtoType(Type::tvoid->arrayOf());
    inits.push_back(getNullValue(T));
}

void TypeInfoBuilder::push_void_array(uint64_t dim, llvm::Constant* ptr)
{
    inits.push_back(DtoConstSlice(
        DtoConstSize_t(dim),
        DtoBitCast(ptr, getVoidPtrType())
        ));
}

void TypeInfoBuilder::push_void_array(llvm::Constant* CI, Type* valtype, Dsymbol* mangle_sym)
{
    std::string initname(mangle_sym->mangle());
    initname.append(".rtti.void[].data");

    LLGlobalVariable* G = new llvm::GlobalVariable(
        CI->getType(), true, TYPEINFO_LINKAGE_TYPE, CI, initname, gIR->module);
    G->setAlignment(valtype->alignsize());

    size_t dim = getTypePaddedSize(CI->getType());
    LLConstant* ptr = DtoBitCast(CI, DtoType(valtype->pointerTo()));

    push_void_array(dim, G);
}

void TypeInfoBuilder::push_array(llvm::Constant * CI, uint64_t dim, Type* valtype, Dsymbol * mangle_sym)
{
    std::string initname(mangle_sym?mangle_sym->mangle():".ldc");
    initname.append(".rtti.");
    initname.append(valtype->arrayOf()->toChars());
    initname.append(".data");

    LLGlobalVariable* G = new llvm::GlobalVariable(
        CI->getType(), true, TYPEINFO_LINKAGE_TYPE, CI, initname, gIR->module);
    G->setAlignment(valtype->alignsize());

    inits.push_back(DtoConstSlice(
        DtoConstSize_t(dim),
        DtoBitCast(CI, DtoType(valtype->pointerTo()))
        ));
}

void TypeInfoBuilder::push_uint(unsigned u)
{
    inits.push_back(DtoConstUint(u));
}

void TypeInfoBuilder::push_size(uint64_t s)
{
    inits.push_back(DtoConstSize_t(s));
}

void TypeInfoBuilder::push_funcptr(FuncDeclaration* fd)
{
    if (fd)
    {
        fd->codegen(Type::sir);
        LLConstant* F = fd->ir.irFunc->func;
        inits.push_back(F);
    }
    else
    {
        push_null_vp();
    }
}

void TypeInfoBuilder::finalize(IrGlobal* tid)
{
    // create the inititalizer
    LLConstant* tiInit = llvm::ConstantStruct::get(&inits[0], inits.size(), false);

    // refine global type
    llvm::cast<llvm::OpaqueType>(tid->type.get())->refineAbstractTypeTo(tiInit->getType());

    // set the initializer
    isaGlobalVar(tid->value)->setInitializer(tiInit);
}