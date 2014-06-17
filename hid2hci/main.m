//
//  main.m
//  hid2hci
//
// Simply taken from the patch found in:
// http://www.spinics.net/lists/linux-bluetooth/msg41964.html
// with the default apple doc example on how to find and
// issue low level command.
//
//  Copyright (c) 2014 Dirk-Willem van Gulik. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import <Foundation/Foundation.h>
#import <IOKit/usb/IOUSBLib.h>
#include <mach/mach.h>

#define kCambridgeRadioID           (0x0a12)
#define kOurProductID               (0x100b) // 0001 is the radio version.


IOReturn switchDevice(IOUSBDeviceInterface **dev)
{
    IOUSBDevRequest     request;
    
    
    char report[] = { 0x1 , 0x5 , 0x0 , 0x0 , 0x0 , 0x0 , 0x0 , 0x0 , 0x0 };

    request.bmRequestType = USBmakebmRequestType(kUSBOut, kUSBClass, kUSBInterface);
    request.bRequest = kUSBRqSetConfig;
    request.wValue = 0x01 | (0x03 << 8), //report id: 0x01, report type: feature (0x03)
    request.wIndex = 0; // intrface 0
    request.wLength = sizeof(report);
    request.pData = report;
    request.wLenDone = 0;
    
    return (*dev)->DeviceRequest(dev, &request);
}

IOReturn ConfigureDevice(IOUSBDeviceInterface **dev)
{
    UInt8                           numConfig;
    IOReturn                        kr;
    IOUSBConfigurationDescriptorPtr configDesc;
    
    //Get the number of configurations. The sample code always chooses
    //the first configuration (at index 0) but your code may need a
    //different one
    kr = (*dev)->GetNumberOfConfigurations(dev, &numConfig);
    if (!numConfig)
        return -1;
    
    //Get the configuration descriptor for index 0
    kr = (*dev)->GetConfigurationDescriptorPtr(dev, 0, &configDesc);
    if (kr)
    {
        printf("Couldn’t get configuration descriptor for index %d (err = %08x)\n", 0, kr);
        return -1;
    }
    
    //Set the device’s configuration. The configuration value is found in
    //the bConfigurationValue field of the configuration descriptor
    kr = (*dev)->SetConfiguration(dev, configDesc->bConfigurationValue);
    if (kr)
    {
        printf("Couldn’t set configuration to value %d (err = %08x)\n", 0,
               kr);
        return -1;
    }
    return kIOReturnSuccess;
}

void RawDeviceAdded(void *refCon, io_iterator_t iterator)
{
    kern_return_t               kr;
    io_service_t                usbDevice;
    IOCFPlugInInterface         **plugInInterface = NULL;
    IOUSBDeviceInterface        **dev = NULL;
    HRESULT                     result;
    SInt32                      score;
    UInt16                      vendor;
    UInt16                      product;
    
    while ((usbDevice = IOIteratorNext(iterator)))
    {
        //Create an intermediate plug-in
        kr = IOCreatePlugInInterfaceForService(usbDevice,
                                               kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
                                               &plugInInterface, &score);
        //Don’t need the device object after intermediate plug-in is created
        kr = IOObjectRelease(usbDevice);
        if ((kIOReturnSuccess != kr) || !plugInInterface)
        {
            printf("Unable to create a plug-in (%08x)\n", kr);
            continue;
        }
        //Now create the device interface
        result = (*plugInInterface)->QueryInterface(plugInInterface,
                                                    CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                                                    (LPVOID *)&dev);
        //Don’t need the intermediate plug-in after device interface
        //is created
        (*plugInInterface)->Release(plugInInterface);
        
        if (result || !dev)
        {
            printf("Couldn’t create a device interface (%08x)\n",
                   (int) result);
            continue;
        }
        
        //Check these values for confirmation
        kr = (*dev)->GetDeviceVendor(dev, &vendor);
        kr = (*dev)->GetDeviceProduct(dev, &product);
        
        if ((vendor != kCambridgeRadioID) || (product != kOurProductID))
        {
            printf("Found unwanted device (Vendor 0x%04x = 0x%04x, product 0x%04x = 0x%04x)\n",
                   kCambridgeRadioID, vendor, kOurProductID, product);
            (void) (*dev)->Release(dev);
            continue;
        }
        
        //Open the device to change its state
        kr = (*dev)->USBDeviceOpen(dev);
        if (kr != kIOReturnSuccess)
        {
            printf("Unable to open device: %08x\n", kr);
            (void) (*dev)->Release(dev);
            continue;
        }
        //Configure device
        kr = ConfigureDevice(dev);
        if (kr != kIOReturnSuccess)
        {
            printf("Unable to configure device: %08x\n", kr);
            (void) (*dev)->USBDeviceClose(dev);
            (void) (*dev)->Release(dev);
            continue;
        }
        
        kr = switchDevice(dev);
        if (kr != kIOReturnSuccess)
        {
            printf("Unable to switch device: %08x/%d%s\n", kr, kr, 
                   (kr == kIOUSBTransactionTimeout) ? " (USB Transaction Timeout)" : "");
            
            (void) (*dev)->USBDeviceClose(dev);
            (void) (*dev)->Release(dev);
            continue;
        }
        
        printf("CSR8510-A10 switched\n");
        
        //Close this device and release object
        kr = (*dev)->USBDeviceClose(dev);
        kr = (*dev)->Release(dev);
    }
}

void RawDeviceRemoved(void *refCon, io_iterator_t iterator)
{
    kern_return_t   kr;
    io_service_t    object;
    
    while ((object = IOIteratorNext(iterator)))
    {
        kr = IOObjectRelease(object);
        if (kr != kIOReturnSuccess)
        {
            printf("Couldn’t release raw device object: %08x\n", kr);
            continue;
        }
    }
}

int main(int argc, const char * argv[])
{

    @autoreleasepool {
        mach_port_t             masterPort;
        CFMutableDictionaryRef  matchingDict;
        CFRunLoopSourceRef      runLoopSource;
        kern_return_t           kr;
        SInt32                  usbVendor = kCambridgeRadioID;
        SInt32                  usbProduct = kOurProductID;

        io_iterator_t            gRawRemovedIter;
        io_iterator_t            gRawAddedIter;
        IONotificationPortRef    gNotifyPort;

        if (argc > 3)
        {
            printf("Syntax: %s [usbVendor [usbProduct]]\n", argv[0]);
            return -1;
        }
        
        if (argc > 1)
            usbVendor = atoi(argv[1]);
        if (argc > 2)
            usbProduct = atoi(argv[2]);
        
        //Create a master port for communication with the I/O Kit
        kr = IOMasterPort(MACH_PORT_NULL, &masterPort);
        if (kr || !masterPort)
        {
            printf("ERR: Couldn’t create a master I/O Kit port(%08x)\n", kr);
            return -1;
        }
        //Set up matching dictionary for class IOUSBDevice and its subclasses
        matchingDict = IOServiceMatching(kIOUSBDeviceClassName);
        if (!matchingDict)
        {
            printf("Couldn’t create a USB matching dictionary\n");
            mach_port_deallocate(mach_task_self(), masterPort);
            return -1;
        }
        
        //Add the vendor and product IDs to the matching dictionary.
        //This is the second key in the table of device-matching keys of the
        //USB Common Class Specification
        CFDictionarySetValue(matchingDict, CFSTR(kUSBVendorName),
                             CFNumberCreate(kCFAllocatorDefault,
                                            kCFNumberSInt32Type, &usbVendor));
        CFDictionarySetValue(matchingDict, CFSTR(kUSBProductName),
                             CFNumberCreate(kCFAllocatorDefault,
                                            kCFNumberSInt32Type, &usbProduct));
        
        //To set up asynchronous notifications, create a notification port and
        //add its run loop event source to the program’s run loop
        gNotifyPort = IONotificationPortCreate(masterPort);
        runLoopSource = IONotificationPortGetRunLoopSource(gNotifyPort);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource,
                           kCFRunLoopDefaultMode);
        
        //Retain additional dictionary references because each call to
        //IOServiceAddMatchingNotification consumes one reference
        matchingDict = (CFMutableDictionaryRef) CFRetain(matchingDict);
        matchingDict = (CFMutableDictionaryRef) CFRetain(matchingDict);
        matchingDict = (CFMutableDictionaryRef) CFRetain(matchingDict);
        
        //Now set up two notifications: one to be called when a raw device
        //is first matched by the I/O Kit and another to be called when the
        //device is terminated
        //Notification of first match:
        kr = IOServiceAddMatchingNotification(gNotifyPort,
                                              kIOFirstMatchNotification, matchingDict,
                                              RawDeviceAdded, NULL, &gRawAddedIter);
        //Iterate over set of matching devices to access already-present devices
        //and to arm the notification
        RawDeviceAdded(NULL, gRawAddedIter);
        
        //Notification of termination:
        kr = IOServiceAddMatchingNotification(gNotifyPort,
                                              kIOTerminatedNotification, matchingDict,
                                              RawDeviceRemoved, NULL, &gRawRemovedIter);
        //Iterate over set of matching devices to release each one and to
        //arm the notification
        RawDeviceRemoved(NULL, gRawRemovedIter);
        //Finished with master port
        mach_port_deallocate(mach_task_self(), masterPort);
        masterPort = 0;
        
        //Start the run loop so notifications will be received
        CFRunLoopRun();
        
        //Because the run loop will run forever until interrupted,
        //the program should never reach this point
        return 0;
    }
    return 0;
}

