## Notes

Using OpenZeppelin 3.x because UniswapV3 INonfungiblePositionManager uses import path that is not compatible with OpenZeppelin 4.x. Was unable to get file-level remapping occur for a single contract (i.e. set remapping path for a single contract, that differs from all others contracts sharing the remapped dependency folder)
