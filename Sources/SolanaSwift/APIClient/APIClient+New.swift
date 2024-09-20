//
//  File.swift
//  
//
//  Created by Alan on 2024/9/20.
//

import Foundation

public struct LatestBlockhash: Decodable {
    public let blockhash: String?
    public let lastValidBlockHeight: UInt64?
}

extension SolanaAPIClient {
    public func getLatestBlockhash(commitment: Commitment? = nil) async throws -> String {
        let result: Rpc<LatestBlockhash> = try await get(method: "getLatestBlockhash",
                                             params: [RequestConfiguration(commitment: commitment)])
        guard let blockhash = result.value.blockhash else {
            throw APIClientError.blockhashNotFound
        }
        return blockhash
    }
    
    func getFeeForMessage(message: String, commitment: Commitment? = nil) async throws -> UInt64? {
        let result: Rpc<UInt64?> = try await get(method: "getFeeForMessage",
                                                 params: [RequestConfiguration(commitment: commitment)])
        
        return result.value
    }
}
