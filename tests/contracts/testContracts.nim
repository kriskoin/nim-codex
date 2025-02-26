import pkg/chronos
import pkg/ethers/testing
import pkg/ethers/erc20
import codex/contracts
import ../ethertest
import ./examples
import ./time
import ./deployment

ethersuite "Marketplace contracts":
  let proof = Groth16Proof.example

  var client, host: Signer
  var marketplace: Marketplace
  var token: Erc20Token
  var periodicity: Periodicity
  var request: StorageRequest
  var slotId: SlotId

  proc switchAccount(account: Signer) =
    marketplace = marketplace.connect(account)
    token = token.connect(account)

  setup:
    client = ethProvider.getSigner(accounts[0])
    host = ethProvider.getSigner(accounts[1])

    let address = Marketplace.address(dummyVerifier = true)
    marketplace = Marketplace.new(address, ethProvider.getSigner())

    let tokenAddress = await marketplace.token()
    token = Erc20Token.new(tokenAddress, ethProvider.getSigner())

    let config = await marketplace.config()
    periodicity = Periodicity(seconds: config.proofs.period)

    request = StorageRequest.example
    request.client = await client.getAddress()

    switchAccount(client)
    discard await token.approve(marketplace.address, request.price)
    discard await marketplace.requestStorage(request)
    switchAccount(host)
    discard await token.approve(marketplace.address, request.ask.collateral)
    discard await marketplace.fillSlot(request.id, 0.u256, proof)
    slotId = request.slotId(0.u256)

  proc waitUntilProofRequired(slotId: SlotId) {.async.} =
    let currentPeriod = periodicity.periodOf(await ethProvider.currentTime())
    await ethProvider.advanceTimeTo(periodicity.periodEnd(currentPeriod))
    while not (
      (await marketplace.isProofRequired(slotId)) and
      (await marketplace.getPointer(slotId)) < 250
    ):
      await ethProvider.advanceTime(periodicity.seconds)

  proc startContract() {.async.} =
    for slotIndex in 1..<request.ask.slots:
      discard await token.approve(marketplace.address, request.ask.collateral)
      discard await marketplace.fillSlot(request.id, slotIndex.u256, proof)

  test "accept marketplace proofs":
    switchAccount(host)
    await waitUntilProofRequired(slotId)
    discard await marketplace.submitProof(slotId, proof)

  test "can mark missing proofs":
    switchAccount(host)
    await waitUntilProofRequired(slotId)
    let missingPeriod = periodicity.periodOf(await ethProvider.currentTime())
    let endOfPeriod = periodicity.periodEnd(missingPeriod)
    await ethProvider.advanceTimeTo(endOfPeriod + 1)
    switchAccount(client)
    discard await marketplace.markProofAsMissing(slotId, missingPeriod)

  test "can be paid out at the end":
    switchAccount(host)
    let address = await host.getAddress()
    await startContract()
    let requestEnd = await marketplace.requestEnd(request.id)
    await ethProvider.advanceTimeTo(requestEnd.u256 + 1)
    let startBalance = await token.balanceOf(address)
    discard await marketplace.freeSlot(slotId)
    let endBalance = await token.balanceOf(address)
    check endBalance == (startBalance + request.ask.duration * request.ask.reward + request.ask.collateral)

  test "cannot mark proofs missing for cancelled request":
    let expiry = await marketplace.requestExpiry(request.id)
    await ethProvider.advanceTimeTo((expiry + 1).u256)
    switchAccount(client)
    let missingPeriod = periodicity.periodOf(await ethProvider.currentTime())
    await ethProvider.advanceTime(periodicity.seconds)
    check await marketplace
      .markProofAsMissing(slotId, missingPeriod)
      .reverts("Slot not accepting proofs")
