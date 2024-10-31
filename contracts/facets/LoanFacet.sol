// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;


import "../libraries/LibDiamond.sol";
import "./ERC721Facet.sol";
import "./ERC20Facet.sol";

error MaxLoanAmountExceeded();
error AddressZeroNotAllowed();
error NftNotAccepted();
error InsufficientNftBalance();
error InsufficientTokenBalance();
error UserNotOwner();

event LoanRequestSuccessfull(address _borrower, address _nft, uint128 _tokenId, address _token, uint256 _amount, uint256 _duration, uint256 _interest, uint256 _timestamp);

event LoanRepaymentSuccessful(address _borrower, address _nft, uint128 _tokenId, address _token, uint256 _amount, uint256 _duration, uint256 _interest, uint256 _timestamp);


contract LoanFacet {

    /**
     * @notice Estimate repayment interest for a given NFT, loan amount, and duration.
     * @param _nft The NFT address used as collateral.
     * @param _amount The loan amount in tokens.
     * @param _duration The loan duration in seconds.
     * @return The calculated interest for the specified loan.
    */
    function estimateRepaymentAmount(address _nft, uint256 _amount, uint256 _duration) internal view returns (uint256) {
        LibDiamond.DiamondStorage storage l = LibDiamond.diamondStorage();
        if (!l.acceptedNft[_nft]) revert NftNotAccepted();
        uint8 rate = l.nftCollateralRate[_nft];
        uint256 interest = (_amount * rate * _duration) / (100 * 365 * 24 * 60 * 60);
        return interest;
    }


    /**
     * @notice Request a loan by locking an NFT as collateral.
     * @param _nft The address of the NFT contract.
     * @param _amount The amount of the loan in tokens.
     * @param _duration The duration of the loan in seconds.
     * @param _tokenId The ID of the NFT token being used as collateral.
     * @dev This function transfers the NFT to the contract and transfers loan tokens to the borrower.
    */
    function requestLoan(address _nft, uint256 _amount, uint256 _duration, uint128 _tokenId) external {

        if (msg.sender == address(0)) revert AddressZeroNotAllowed();

        LibDiamond.DiamondStorage storage l = LibDiamond.diamondStorage();

        if (_amount > l.nftCollateralMaxLoanAmount[_nft]) revert MaxLoanAmountExceeded();
        if (!l.acceptedNft[_nft]) revert NftNotAccepted();
        if (ERC721Facet(_nft).balanceOf(msg.sender) == 0) revert InsufficientNftBalance();

        // Check if the user owns the specific tokenId
        if (ERC721Facet(_nft).ownerOf(_tokenId) != msg.sender) revert UserNotOwner();
        
        uint interest = estimateRepaymentAmount(_nft, _amount, _duration);

        ++l.nftBalance[msg.sender][_nft];
        
        l.loans[msg.sender].push(LibDiamond.Loan(msg.sender, _nft, _tokenId, address(ERC721Facet(l.tokenAddress)), _amount, _duration, interest, block.timestamp + _duration));

        // Transfer the specified tokenId
        ERC721Facet(_nft).transferFrom(msg.sender, address(this), _tokenId);
        (bool s) = ERC20Facet(l.tokenAddress).transfer(msg.sender, _amount);
        require(s);

        emit LoanRequestSuccessfull(msg.sender, _nft, _tokenId, l.tokenAddress, _amount, _duration, interest, block.timestamp);
    }


    /**
     * @notice Calculate additional overhead if loan is overdue.
     * @param _amount The initial loan amount.
     * @param _i The index of the loan in the borrower's loan array.
     * @return overhead The calculated penalty for overdue repayment.
    */
    function calculateOverhead(uint256 _amount, uint8 _i) internal view returns (uint256 overhead) {
        LibDiamond.DiamondStorage storage l = LibDiamond.diamondStorage();
        LibDiamond.Loan storage userLoan = l.loans[msg.sender][_i];

        uint256 dueDate  = userLoan.dueDate;

        if (dueDate < block.timestamp) {
            uint256 daysOverdue = (block.timestamp - dueDate) / 86400;
            overhead = (_amount * 5 * daysOverdue) / 100;
        }
    }


    /**
     * @notice Repay a loan and reclaim collateral if successful.
     * @param _i The index of the loan in the borrower's loan array.
     * @dev Reclaims NFT collateral and handles overdue penalties if applicable.
    */
    function repayLoan(uint8 _i) external {
        if (msg.sender == address(0)) revert AddressZeroNotAllowed();
        LibDiamond.DiamondStorage storage l = LibDiamond.diamondStorage();
        LibDiamond.Loan storage userLoan = l.loans[msg.sender][_i];

        if (ERC20Facet(userLoan.token).balanceOf(msg.sender) >= userLoan.tokenAmount + userLoan.interest) revert InsufficientTokenBalance();
        if (l.nftBalance[msg.sender][userLoan.nft] == 0) revert InsufficientNftBalance();

        --l.nftBalance[msg.sender][userLoan.nft];

        if (userLoan.dueDate < block.timestamp) {
            uint256 overhead = calculateOverhead(userLoan.tokenAmount, _i);
            (bool successWithOverhead) = ERC20Facet(userLoan.token).transfer(msg.sender, userLoan.tokenAmount + userLoan.interest + overhead);
            require(successWithOverhead);
        }else {
            (bool successWithoutOverhead) = ERC20Facet(userLoan.token).transfer(msg.sender, userLoan.tokenAmount + userLoan.interest);
            require(successWithoutOverhead);
        }

        ERC721Facet(userLoan.nft).transferFrom(address(this), msg.sender, userLoan.tokenId);

        emit LoanRepaymentSuccessful(msg.sender, userLoan.nft, userLoan.tokenId, userLoan.token, userLoan.tokenAmount, userLoan.duration, userLoan.interest, block.timestamp);
        
    }

}