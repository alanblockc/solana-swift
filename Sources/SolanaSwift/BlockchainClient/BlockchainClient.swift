import Foundation

public enum BlockchainClientError: Error, Equatable {
    case sendTokenToYourSelf
    case invalidAccountInfo
    case other(String)
}

/// Default implementation of SolanaBlockchainClient
public class SolanaBlockchainClient {
    public var apiClient: SolanaAPIClient
    
    public init(apiClient: SolanaAPIClient) {
        self.apiClient = apiClient
    }
    
    /// Prepare a transaction to be sent using SolanaBlockchainClient
    /// - Parameters:
    ///   - instructions: the instructions of the transaction
    ///   - signers: the signers of the transaction
    ///   - feePayer: the feePayer of the transaction
    ///   - feeCalculator: (Optional) fee custom calculator for calculating fee
    /// - Returns: PreparedTransaction, can be sent or simulated using SolanaBlockchainClient
    public func prepareTransaction(
        instructions: [TransactionInstruction],
        signers: [KeyPair],
        feePayer: PublicKey
    ) async throws -> PreparedTransaction {
        // form transaction
        var transaction = Transaction(instructions: instructions, recentBlockhash: nil, feePayer: feePayer)
        
        //        let feeCalculator: FeeCalculator
        //        if let fc = fc {
        //            feeCalculator = fc
        //        } else {
        //            let (lps, minRentExemption) = try await(
        //                apiClient.getFees(commitment: nil).feeCalculator?.lamportsPerSignature,
        //                apiClient.getMinimumBalanceForRentExemption(span: 165)
        //            )
        //            let lamportsPerSignature = lps ?? 5000
        //            feeCalculator = DefaultFeeCalculator(
        //                lamportsPerSignature: lamportsPerSignature,
        //                minRentExemption: minRentExemption
        //            )
        //        }
        
        
        let blockhash = try await apiClient.getLatestBlockhash()
        transaction.recentBlockhash = blockhash
        
        // if any signers, sign
        if !signers.isEmpty {
            try transaction.sign(signers: signers)
        }
        
        let expectedFee = try await apiClient.getFeeForMessage(message: transaction.serializeMessage().base64EncodedString())
        
        // return formed transaction
        return .init(transaction: transaction, signers: signers, expectedFee: expectedFee)
    }
    
    /// Create prepared transaction for sending SOL
    /// - Parameters:
    ///   - account
    ///   - to: destination wallet address
    ///   - amount: amount in lamports
    ///   - feePayer: customm fee payer, can be omited if the authorized user is the payer
    ///    - recentBlockhash optional
    /// - Returns: PreparedTransaction, can be sent or simulated using SolanaBlockchainClient
    public func prepareSendingNativeSOL(
        account: KeyPair?,
        from fromWalletAddr: String,
        to toWalletAddr: String,
        amount: UInt64,
        feePayer: PublicKey? = nil
    ) async throws -> PreparedTransaction {
        let fromPublicKey = try PublicKey(string: fromWalletAddr)
        let feePayer = feePayer ?? fromPublicKey
        
        if fromPublicKey.base58EncodedString == toWalletAddr {
            throw BlockchainClientError.sendTokenToYourSelf
        }
        var accountInfo: BufferInfo<EmptyInfo>?
        do {
            accountInfo = try await apiClient.getAccountInfo(account: toWalletAddr)
            guard accountInfo == nil || accountInfo?.owner == SystemProgram.id.base58EncodedString
            else { throw BlockchainClientError.invalidAccountInfo }
        } catch let error as APIClientError where error == .couldNotRetrieveAccountInfo {
            // ignoring error
            accountInfo = nil
        } catch {
            throw error
        }
        
        // form instruction
        let instruction = try SystemProgram.transferInstruction(
            from: fromPublicKey,
            to: PublicKey(string: toWalletAddr),
            lamports: amount
        )
        return try await prepareTransaction(
            instructions: [instruction],
            signers: (account != nil) ? [account!]: [],
            feePayer: feePayer
        )
    }
    
    /// Prepare for sending any SPLToken
    /// - Parameters:
    ///   - account: user's account to send from
    ///   - mintAddress: mint address of sending token
    ///   - decimals: decimals of the sending token
    ///   - fromPublicKey: the concrete spl token address in user's account
    ///   - destinationAddress: the destination address, can be token address or native Solana address
    ///   - amount: amount to be sent
    ///   - feePayer: (Optional) if the transaction would be paid by another user
    ///   - transferChecked: (Default: false) use transferChecked instruction instead of transfer transaction
    ///   - minRentExemption: (Optional) pre-calculated min rent exemption, will be fetched if not provided
    /// - Returns: (preparedTransaction: PreparedTransaction, realDestination: String), preparedTransaction can be sent
    /// or simulated using SolanaBlockchainClient, the realDestination is the real spl address of destination. Can be
    /// different from destinationAddress if destinationAddress is a native Solana address
    public func prepareSendingSPLTokens(
        account: KeyPair,
        mintAddress: String,
        tokenProgramId: PublicKey,
        decimals: Decimals,
        from fromWalletAddr: String,
        to toWalletAddr: String,
        amount: UInt64,
        feePayer: PublicKey? = nil,
        transferChecked: Bool = false
    ) async throws -> (preparedTransaction: PreparedTransaction, realDestination: String) {
        let feePayer = feePayer ?? account.publicKey
    
        // get from tokenAccount
        let fromTokenAccountAddr = try await apiClient.findSPLTokenDestinationAddress(mintAddress: mintAddress, destinationAddress: fromWalletAddr, tokenProgramId: tokenProgramId).destination.base58EncodedString
        let fromTokenPublicKey = try PublicKey(string: fromTokenAccountAddr)
        
        // get to tokenAccount
        let splDestination = try await apiClient.findSPLTokenDestinationAddress(
            mintAddress: mintAddress,
            destinationAddress: toWalletAddr,
            tokenProgramId: tokenProgramId
        )
        let toTokenPublicKey = splDestination.destination
        
        // catch error
        if fromWalletAddr == toTokenPublicKey.base58EncodedString {
            throw BlockchainClientError.sendTokenToYourSelf
        }
        
        var instructions = [TransactionInstruction]()
        
        if splDestination.isUnregisteredAsocciatedToken {
            let mint = try PublicKey(string: mintAddress)
            let owner = try PublicKey(string: toWalletAddr)
            
            let createATokenInstruction = try AssociatedTokenProgram.createAssociatedTokenAccountInstruction(
                mint: mint,
                owner: owner,
                payer: feePayer,
                tokenProgramId: tokenProgramId
            )
            instructions.append(createATokenInstruction)
        }
        
        // send instruction
        let sendInstruction: TransactionInstruction
        
        // use transfer checked transaction for proxy, otherwise use normal transfer transaction
        if transferChecked {
            // transfer checked transaction
            if tokenProgramId == TokenProgram.id {
                sendInstruction = try TokenProgram.transferCheckedInstruction(
                    source: fromTokenPublicKey,
                    mint: PublicKey(string: mintAddress),
                    destination: toTokenPublicKey,
                    owner: account.publicKey,
                    multiSigners: [],
                    amount: amount,
                    decimals: decimals
                )
            } else {
                sendInstruction = try Token2022Program.transferCheckedInstruction(
                    source: fromTokenPublicKey,
                    mint: PublicKey(string: mintAddress),
                    destination: toTokenPublicKey,
                    owner: account.publicKey,
                    multiSigners: [],
                    amount: amount,
                    decimals: decimals
                )
            }
        } else {
            // transfer transaction
            if tokenProgramId == TokenProgram.id {
                sendInstruction = TokenProgram.transferInstruction(
                    source: fromTokenPublicKey,
                    destination: toTokenPublicKey,
                    owner: account.publicKey,
                    amount: amount
                )
            } else {
                sendInstruction = Token2022Program.transferInstruction(
                    source: fromTokenPublicKey,
                    destination: toTokenPublicKey,
                    owner: account.publicKey,
                    amount: amount
                )
            }
        }
        
        instructions.append(sendInstruction)
        
        var realDestination = toWalletAddr
        if !splDestination.isUnregisteredAsocciatedToken {
            realDestination = splDestination.destination.base58EncodedString
        }
        
        // if not, serialize and send instructions normally
        let preparedTransaction = try await prepareTransaction(
            instructions: instructions,
            signers: [account],
            feePayer: feePayer
        )
        return (preparedTransaction, realDestination)
    }
}
