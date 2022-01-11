import std/os
import std/options

import pkg/asynctest
import pkg/chronos
import pkg/stew/byteutils

import pkg/nitro
import pkg/libp2p
import pkg/libp2p/errors

import pkg/dagger/stores
import pkg/dagger/blockexchange
import pkg/dagger/chunker
import pkg/dagger/node
import pkg/dagger/manifest
import pkg/dagger/blocktype as bt

import ./helpers

suite "Test Node":
  let
    (path, _, _) = instantiationInfo(-2, fullPaths = true) # get this file's name

  var
    file: File
    chunker: Chunker
    switch: Switch
    wallet: WalletRef
    network: BlockExcNetwork
    localStore: MemoryStore
    engine: BlockExcEngine
    store: NetworkStore
    node: DaggerNodeRef

  setup:
    file = open(path.splitFile().dir /../ "fixtures" / "test.jpg")
    chunker = FileChunker.new(file = file)
    switch = newStandardSwitch()
    wallet = WalletRef.new(EthPrivateKey.random())
    network = BlockExcNetwork.new(switch)
    localStore = MemoryStore.new()
    engine = BlockExcEngine.new(localStore, wallet, network)
    store = NetworkStore.new(engine, localStore)
    node = DaggerNodeRef.new(switch, store, engine)

    await node.start()

  teardown:
    close(file)
    await node.stop()

  test "Store Data Stream":
    let
      stream = BufferStream.new()
      storeFut = node.store(stream)

    var
      manifest = BlocksManifest.init().get()

    try:
      while (
        let chunk = await chunker.getBytes();
        chunk.len > 0):
        await stream.pushData(chunk)
        manifest.put(bt.Block.init(chunk).get().cid)
    finally:
      await stream.pushEof()
      await stream.close()

    let
      manifestCid = (await storeFut).get()

    check:
      manifestCid in localStore

    var
      manifestBlock = (await localStore.getBlock(manifestCid)).get()
      localManifest = BlocksManifest.init(manifestBlock).get()

    check:
      manifest.len == localManifest.len
      manifest.cid == localManifest.cid

  test "Retrieve Data Stream":
    var
      manifest = BlocksManifest.init().get()
      original: seq[byte]

    while (
      let chunk = await chunker.getBytes();
      chunk.len > 0):

      let
        blk = bt.Block.init(chunk).get()

      original &= chunk
      check await localStore.putBlock(blk)
      manifest.put(blk.cid)

    let
      manifestBlock = bt.Block.init(
        manifest.encode().get(),
        codec = ManifestCodec).get()

    check await localStore.putBlock(manifestBlock)

    let stream = BufferStream.new()
    check (await node.retrieve(stream, manifestBlock.cid)).isOk

    var data: seq[byte]
    while true:
      var
        buf = newSeq[byte](FileChunkSize)
        res = await stream.readOnce(addr buf[0], buf.len)

      if res <= 0:
        break

      buf.setLen(res)
      data &= buf

    check data == original

  test "Retrieve One Block":
    let
      testString = "Block 1"
      blk = bt.Block.init(testString.toBytes).get()

    var
      stream = BufferStream.new()

    check (await localStore.putBlock(blk))
    check (await node.retrieve(stream, blk.cid)).isOk

    var data = newSeq[byte](testString.len)
    await stream.readExactly(addr data[0], data.len)
    check string.fromBytes(data) == testString
