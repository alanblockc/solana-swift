import Foundation

/// The prepared transaction that can be sent or simulate in SolanaBlockchainClient
public struct PreparedVersionedTransaction: Equatable {
    public var transaction: VersionedTransaction
    public var expectedFee: UInt64?

    public init(transaction: VersionedTransaction, expectedFee: UInt64?) {
        self.transaction = transaction
        self.expectedFee = expectedFee
    }
}
