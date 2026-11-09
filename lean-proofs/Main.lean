import CodeDB.OpenPufferLifecycle
import CodeDB.OpenPufferSearch
import CodeDB.SearchLifecycle
import CodeDB.SearchCache

def main : IO Unit := do
  IO.println s!"OpenPufferLifecycle: cube={CodeDB.OpenPufferLifecycle.lifecycleCubeSize} planOk={CodeDB.OpenPufferLifecycle.planInsertCubeOk} slabOk={CodeDB.OpenPufferLifecycle.appendRecordCubeOk} commitOk={CodeDB.OpenPufferLifecycle.commitInsertCubeOk}"
  IO.println s!"OpenPufferSearch:    cube={CodeDB.OpenPufferSearch.searchCubeSize} visitedEquiv={CodeDB.OpenPufferSearch.visitedEquivCubeOk} dualAccDotEquiv={CodeDB.OpenPufferSearch.dualAccEquivCubeOk} stackBufOk={CodeDB.OpenPufferSearch.stackAllocCubeOk}"
  IO.println s!"SearchLifecycle:     cube={CodeDB.SearchLifecycle.searchLifecycleCubeSize} lifecycleOk={CodeDB.SearchLifecycle.searchLifecycleCubeOk}"
  IO.println s!"SearchCache:         cube={CodeDB.SearchCache.searchCacheCubeSize} envMemoOk={CodeDB.SearchCache.envMemoCubeOk} cacheConservationOk={CodeDB.SearchCache.cacheConservationCubeOk} lazyGenOk={CodeDB.SearchCache.lazyGenCubeOk}"
