pragma solidity ^0.5.12;

import { LibNote } from "dss/lib.sol";
import {BCdpManager} from "./../BCdpManager.sol";
import {Math} from "./../Math.sol";

import { DSAuth } from "ds-auth/auth.sol";

contract VatLike {
    function urns(bytes32 ilk, address u) public view returns (uint ink, uint art);
    function ilks(bytes32 ilk) public view returns(uint Art, uint rate, uint spot, uint line, uint dust);
    function flux(bytes32 ilk, address src, address dst, uint256 wad) external;
    function move(address src, address dst, uint256 rad) external;
    function hope(address usr) external;
    function dai(address usr) external view returns(uint);
}

contract PriceFeedLike {
    function peek(bytes32 ilk) external view returns(bytes32,bool);
}

contract SpotLike {
    function par() external view returns (uint256);
    function ilks(bytes32 ilk) external view returns (address pip, uint mat);
}

contract OSMLike {
    function peep() external view returns(bytes32,bool);
    function hop()  external view returns(uint16);
    function zzz()  external view returns(uint64);
}

contract Pool is Math, DSAuth {
    struct CdpData {
        uint       art;        // topup in art units
        address[]  members;    // liquidators that are in
        uint[]     bite;       // how much was already bitten
    }

    address[] public members;
    mapping(bytes32 => bool) public ilks;
    mapping(address => uint) public rad; // mapping from member to its dai balance in rad
    mapping(uint => CdpData) public cdpData;

    VatLike                   public vat;
    BCdpManager               public man;
    SpotLike                  public spot;
    address                   public jar;


    mapping(bytes32 => OSMLike) public osm; // mapping from ilk to osm

    modifier onlyMember {
        bool member = false;
        for(uint i = 0 ; i < members.length ; i++) {
            if(members[i] == msg.sender) member = true;
        }
        require(member, "not-member");
        _;
    }

    constructor(address vat_, address jar_, address spot_) public {
        spot = SpotLike(spot_);
        vat = VatLike(vat_);
        jar = jar_;
    }

    function setCdpManager(BCdpManager man_) external auth { // TODO - make it settable only once, or with timelock
        man = man_;
        vat.hope(address(man));
    }

    function setOsm(bytes32 ilk_, address  osm_) external auth { // TODO - make it settable only once, or with timelock
        osm[ilk_] = OSMLike(osm_);
    }

    function setMembers(address[] calldata members_) external auth {
        members = members_;
    }

    function setIlk(bytes32 ilk, bool set) external auth {
        ilks[ilk] = set;
    }

    function deposit(uint radVal) external onlyMember {
        vat.move(msg.sender, address(this),radVal);
        rad[msg.sender] = add(rad[msg.sender],radVal);
    }

    function withdraw(uint radVal) external onlyMember {
        require(rad[msg.sender] >= radVal, "withdraw: insufficient balance");
        rad[msg.sender] = sub(rad[msg.sender],radVal);
        vat.move(address(this),msg.sender,radVal);
    }

    function getIndex(address[] storage array, address elm) internal view returns(uint) {
        for(uint i = 0 ; i < array.length ; i++) {
            if(array[i] == elm) return i;
        }

        return uint(-1);
    }

    function removeElement(address[] memory array, uint index) internal pure returns(address[] memory newArray) {
        if(index >= array.length) {
            newArray = array;
        }
        else {
            newArray = new address[](array.length - 1);
            for(uint i = 0 ; i < array.length ; i++) {
                if(i == index) continue;
                if(i < index) newArray[i] = array[i];
                else newArray[i-1] = array[i];
            }
        }
    }

    function chooseMembers(uint radVal, address[] memory candidates) public view returns(address[] memory winners) {
        if(candidates.length == 0) return candidates;

        uint need = add(1,radVal / candidates.length);
        for(uint i = 0 ; i < candidates.length ; i++) {
            if(rad[candidates[i]] < need) {
                return chooseMembers(radVal, removeElement(candidates, i));
            }
        }

        winners = candidates;
    }

    function topAmount(uint cdp) public view returns(int dart, int dtab, uint art) {
        address urn = man.urns(cdp);
        bytes32 ilk = man.ilks(cdp);

        if(! ilks[ilk]) return (0,0,0);

        (bytes32 peep, bool valid) = osm[ilk].peep();

        // price feed invalid
        if(! valid) return (0,0,0);

        // too early to topup
        if(now < add(uint(osm[ilk].zzz()),uint(osm[ilk].hop())/2)) return (0,0,0);

        (uint ink, uint curArt) = vat.urns(ilk,urn);
        art = curArt;
        (,uint rate,,,) = vat.ilks(ilk);

        (, uint mat) = spot.ilks(ilk);
        uint par = spot.par();

        uint nextVatSpot = rdiv(rdiv(mul(uint(peep), uint(10 ** 9)), par), mat);

        // rate * art <= spot * ink
        // art <= spot * ink / rate
        uint maximumArt = mul(nextVatSpot,ink) / rate;

        dart = (int(art) - int(maximumArt));
        dtab = mul(rate, dart);
    }

    function resetCdp(uint cdp) internal {
        address[] memory winners = cdpData[cdp].members;

        if(winners.length == 0) return;

        bytes32 ilk = man.ilks(cdp);
        (,uint rate,,,) = vat.ilks(ilk);

        uint refund = cdpData[cdp].art / winners.length;

        uint perUserArt = cdpData[cdp].art / winners.length;
        for(uint i = 0 ; i < winners.length ; i++) {
            if(perUserArt <= cdpData[cdp].bite[i]) continue; // nothing to refund
            uint refundArt = sub(perUserArt,cdpData[cdp].bite[i]);
            rad[winners[i]] = add(rad[winners[i]],mul(refundArt,rate));
        }

        cdpData[cdp].art = 0;
        delete cdpData[cdp].members;
        delete cdpData[cdp].bite;
    }

    function setCdp(uint cdp, address[] memory winners, uint art, uint dradVal) internal {
        uint drad = add(1,dradVal / winners.length); // round up
        for(uint i = 0 ; i < winners.length ; i++) {
            rad[winners[i]] = sub(rad[winners[i]], drad);
        }

        cdpData[cdp].art = art;
        cdpData[cdp].members = winners;
        cdpData[cdp].bite = new uint[](winners.length);
    }


    function topup(uint cdp) external onlyMember {
        require(man.cushion(cdp) == 0, "topup: already-topped");
        require(! man.bitten(cdp), "topup: already-bitten");

        (int dart, int dtab, uint art) = topAmount(cdp);

        require(dart > 0 && dtab > 0, "topup: no-need");

        resetCdp(cdp);

        address[] memory winners = chooseMembers(uint(dtab), members);
        require(winners.length > 0, "topup: members-are-broke");

        setCdp(cdp, winners, uint(art), uint(dtab));

        man.topup(cdp, uint(dart));
    }

    function untop(uint cdp) external onlyMember {
        require(man.cushion(cdp) == 0, "untop: should-be-untopped-by-user");
        require(! man.bitten(cdp), "topup: in-bite-process");

        resetCdp(cdp);
    }

    function bite(uint cdp, uint dart, uint minInk) external onlyMember {
        uint index = getIndex(cdpData[cdp].members, msg.sender);
        require(index < uint(-1), "bite: member-not-elgidabe");

        uint numMembers = cdpData[cdp].members.length;

        uint availArt = sub(cdpData[cdp].art / numMembers, cdpData[cdp].bite[index]);
        require(dart <= availArt, "bite: debt-too-small");

        cdpData[cdp].bite[index] = add(cdpData[cdp].bite[index], dart);

        uint radBefore = vat.dai(address(this));
        uint dink = man.bite(cdp, dart);
        uint radAfter = vat.dai(address(this));

        // update user rad
        rad[msg.sender] = sub(rad[msg.sender],sub(radBefore,radAfter));

        require(dink >= minInk, "bite: low-dink");

        uint userInk = dink / 100;
        bytes32 ilk = man.ilks(cdp);

        vat.flux(ilk, address(this), jar, userInk);
        vat.flux(ilk, address(this), msg.sender, sub(dink,userInk));
    }
}
