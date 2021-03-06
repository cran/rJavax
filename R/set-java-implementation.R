dollarsToJava <- function(object, method)
  toJava(do.call(`$`, list(object, method)))

##' Create the Java object corresponding to the interface proxy.
##' @param interface the interface to proxy
##' @param implementation the implementing proxy
##' @return Java interface-proxy
##' @export
interfaceProxy <- function(interface, implementation)
  new(J('RInterfaceProxy'),
      interface,
      toJava(dollarsToJava),
      toJava(implementation))$newInstance()

##' Create a Java-proxy-interface-backed refClass.
##' @param Class name of the Java interface to be implemented
##' @param fields cf. \code{\link{ReferenceClasses}}
##' @param contains cf. \code{\link{ReferenceClasses}}
##' @param methods cf. cf. \code{\link{ReferenceClasses}}
##' @param implements a character vector of Java interfaces implemented
##' @param extends which Java base class is extended
##' @param where the environment to define the javaRefClass in
##' @param ... arguments to \code{\link{setRefClass}}
##' @return a Java-proxy-interface-backed refClass
##' @include ascend-class-hierarchy.R
##' @export
##' @TODO we need to check that a method is provided for each interface method
setJavaImplementation <- function(Class,
                                  fields = list(),
                                  contains = character(),
                                  methods = list(),
                                  implements = character(),
                                  extends = "java.lang.Object",
                                  where = topenv(parent.frame()),
                                  ...)
{
  if (!length(implements))
    stop("Must provide at least one interface in 'implements'")
  
  for (implement in implements)
    setJavaRefClass(implement, where = where)

  if (!identical(extends, "java.lang.Object"))
    stop("Currently, it is only possible to extend 'java.lang.Object'")
  setJavaRefClass(extends, where = where)
  
  implClassName <- paste(Class, "Impl", sep = "")
  
  delegateMethods <-
    Map(function(method) method$getName(),
        as.list(J('java.lang.Class')$forName(extends)$getDeclaredMethods()))

  delegateMethods <-
    sapply(as.character(unlist(delegateMethods)), function(delegateMethod)
           eval(substitute(function(...) {
             `$`(.delegate, delegateMethod)(...)
           }, list(delegateMethod=delegateMethod))))

  ## Some methods we need to override

  ## getClass
  interfaces <- lapply(implements, J('java.lang.Class')$forName)
  delegateMethods$getClass <- eval(substitute(function() {
    J("java.lang.reflect.Proxy")$getProxyClass(loader, interfaces)
  }, list(loader = interfaces[[1]]$getClassLoader(),
          interfaces = .jarray(interfaces, "java.lang.Class"))))

  ## toString
  delegateMethods$toString <- eval(substitute(function() {
    paste("rJavax object of class '", name, "', implementing ",
          paste("'", implements, "'", collapse = ", ", sep = ""), sep = "")
  }, list(name = Class, implements = implements)))
  
  ## clone
  delegateMethods$clone <- eval(substitute(function() {
    interfaceProxy(implements, new(implClass))
  }, list(implements = implements, implClassName)))

  ## We need to implement java.lang.Object.finalize(), even if it is
  ## just a no-op. The problem is that setRefClass() will register any
  ## method named "finalize" as a finalizer on the R object with
  ## reg.finalizer(). If the user provides a 'finalize' method, we
  ## assume it is to handle the Java call. The R call will come later,
  ## after the Java object has been destroyed (hopefully). Thus, we
  ## rewrite the user 'finalize' to first remove the 'finalize'
  ## method, so that it is not called again.
  if (is.null(methods$finalize))
    methods$finalize <- function() { }
  else {
    finalize_body <- body(methods$finalize)
    if (identical(finalize_body[[1]], as.name("{")))
      finalize_body <- finalize_body[-1]
    finalize_body <- as.call(c(as.name("{"),
                               quote(if (.finalized) return()),
                               quote(.finalized <<- TRUE),
                               finalize_body))
    body(methods$finalize) <- finalize_body
  }
  
  initialize <- methods$initialize
  methods$initialize <- NULL

  delegateMethods[names(methods)] <- methods

  fields$.delegate <- "jobjRef"
  fields$.finalized <- "logical"
  
  setRefClass(implClassName,
              contains = contains,
              fields = fields,
              methods = c(delegateMethods,
                initialize = eval(substitute(function(...) {
                  .finalized <<- FALSE
                  .delegate <<- new(J(extends))
                  if (hasInitialize)
                    initialize(...)
                  else callSuper(...)
                }, list(initialize = initialize,
                        hasInitialize = !is.null(initialize),
                        extends = extends)))
                ),
              where = where, ...)
  
  setRefClass(Class,
              contains = c(extends, implements),
              methods = list(
                initialize = eval(substitute(function(...) {
                  ref <<- interfaceProxy(implements, new(implClass, ...))
                  .self
                }, list(implements = implements,
                        implClass = implClassName)))),
              where = where, ...)
}
